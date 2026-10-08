import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/app_user.dart';
import '../models/post.dart';
import 'post_service.dart';
import 'user_service.dart';

/// What one post or clip did in the chosen period.
class PostInsight {
  const PostInsight({
    required this.post,
    required this.views,
    required this.reach,
    required this.likes,
    required this.comments,
    required this.shares,
    required this.reposts,
    this.viewerIds = const <String>[],
    this.viewsByDay = const <DateTime, int>{},
  });

  final Post post;

  /// How many times it was watched in the period (one person can watch twice).
  final int views;

  /// How many different accounts watched it.
  final int reach;

  final int likes;
  final int comments;
  final int shares;
  final int reposts;

  /// Who watched it (kept so [Insights] can count a person once across all posts).
  final List<String> viewerIds;

  /// Views per day, for the little chart.
  final Map<DateTime, int> viewsByDay;

  int get engagement => likes + comments + shares + reposts;

  /// Likes, comments, shares and reposts per account reached.
  double get engagementRate => reach == 0 ? 0 : engagement / reach;
}

/// Everything the Analytics screen shows, already added up.
class Insights {
  const Insights({
    required this.days,
    required this.posts,
    required this.viewers,
    required this.countries,
    required this.languages,
    required this.followersReached,
    required this.nonFollowersReached,
    required this.followersNow,
    required this.followersGained,
    required this.viewsByDay,
  });

  /// The period that was looked at (7, 30 or 90 days).
  final int days;

  final List<PostInsight> posts;

  /// Everybody who watched something of yours in the period, counted once.
  final Set<String> viewers;

  /// Viewers per country and per language (only for the people we could look up).
  final Map<String, int> countries;
  final Map<String, int> languages;

  /// Of the people reached, how many follow you and how many do not.
  final int followersReached;
  final int nonFollowersReached;

  final int followersNow;
  final int followersGained;

  /// Views per day over the whole period, missing days filled with 0.
  final Map<DateTime, int> viewsByDay;

  /// Builds the numbers from what Firestore gave (no Firestore in here, so it is testable).
  factory Insights.build({
    required int days,
    required List<PostInsight> posts,
    required Map<String, AppUser> people,
    required Set<String> followerIds,
    required Map<String, DateTime?> followerJoined,
    required int followersNow,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final from = Insights.dayOf(at.subtract(Duration(days: days - 1)));

    final viewers = <String>{};
    final byDay = <DateTime, int>{};
    for (final p in posts) {
      viewers.addAll(p.viewerIds);
      p.viewsByDay.forEach((day, seen) {
        byDay[day] = (byDay[day] ?? 0) + seen;
      });
    }
    for (var i = 0; i < days; i++) {
      byDay.putIfAbsent(from.add(Duration(days: i)), () => 0);
    }

    final countries = <String, int>{};
    final languages = <String, int>{};
    for (final uid in viewers) {
      final who = people[uid];
      if (who == null) continue;
      final country = who.country.trim();
      final language = who.language.trim();
      if (country.isNotEmpty) {
        countries[country] = (countries[country] ?? 0) + 1;
      }
      if (language.isNotEmpty) {
        languages[language] = (languages[language] ?? 0) + 1;
      }
    }

    var gained = 0;
    followerJoined.forEach((uid, joined) {
      if (joined != null && !joined.isBefore(from)) gained++;
    });

    return Insights(
      days: days,
      posts: posts,
      viewers: viewers,
      countries: _topOf(countries),
      languages: _topOf(languages),
      followersReached: viewers.intersection(followerIds).length,
      nonFollowersReached: viewers.difference(followerIds).length,
      followersNow: followersNow,
      followersGained: gained,
      viewsByDay: byDay,
    );
  }

  /// Midnight of [at] (the chart works on whole days).
  static DateTime dayOf(DateTime at) => DateTime(at.year, at.month, at.day);

  static Map<String, int> _topOf(Map<String, int> src) {
    final entries = src.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return <String, int>{
      for (final e in entries.take(6)) e.key: e.value,
    };
  }

  int get views => posts.fold(0, (a, p) => a + p.views);

  /// Accounts reached, counted once even if they watched more than one post.
  int get reach => viewers.length;

  int get likes => posts.fold(0, (a, p) => a + p.likes);
  int get comments => posts.fold(0, (a, p) => a + p.comments);
  int get shares => posts.fold(0, (a, p) => a + p.shares);
  int get reposts => posts.fold(0, (a, p) => a + p.reposts);
  int get engagement => likes + comments + shares + reposts;
  int get postsPublished => posts.length;

  double get engagementRate =>
      reach == 0 ? 0 : engagement / reach;

  /// How much of your audience saw something, as a share of your followers.
  double get reachRate =>
      followersNow == 0 ? 0 : reach / followersNow;

  double get avgLikes => posts.isEmpty ? 0 : likes / posts.length;
  double get avgComments => posts.isEmpty ? 0 : comments / posts.length;
  double get avgViews => posts.isEmpty ? 0 : views / posts.length;

  List<PostInsight> get topByReach => _top((p) => p.reach);
  List<PostInsight> get topByEngagement => _top((p) => p.engagement);
  List<PostInsight> get topByViews => _top((p) => p.views);

  List<PostInsight> _top(int Function(PostInsight) by) {
    final list = [...posts]..sort((a, b) => by(b).compareTo(by(a)));
    return list.take(5).toList();
  }

  /// The days of the period, oldest first, with the number of views on each.
  List<int> get dailyViews {
    final days = viewsByDay.keys.toList()..sort();
    return [for (final d in days.take(this.days)) viewsByDay[d] ?? 0];
  }

  bool get isEmpty => posts.isEmpty && viewers.isEmpty;
}

/// Reads the numbers of one account.
///
/// Everything is read from what the app already writes: the view documents
/// (`posts/{id}/views/{uid}`), the counters on each post, and the followers list. There is
/// no analytics service behind it, so the numbers start with this version.
class AnalyticsService {
  AnalyticsService._();
  static final AnalyticsService instance = AnalyticsService._();

  /// How far back the numbers go, at most.
  static const int maxPosts = 60;

  /// How many view documents are read per post.
  static const int maxViewsPerPost = 300;

  /// How many viewer profiles are looked up (for the Audience tab).
  static const int maxPeople = 120;

  /// Tests replace this: it gets the number of days and returns the numbers.
  Future<Insights> Function(int days, String uid, String? postId)? backend;

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  String get _uid => FirebaseAuth.instance.currentUser!.uid;

  /// [postId] gives the numbers of that one post or clip (no date filter on it).
  Future<Insights> load(int days, {String? uid, String? postId}) async {
    final back = backend;
    // The tests answer before anything asks Firebase who is signed in.
    if (back != null) return back(days, uid ?? _safeUid(), postId);
    return _read(days, uid ?? _uid, postId);
  }

  /// Who is signed in, or '' when there is nobody (tests, signed out).
  String _safeUid() {
    try {
      return _uid;
    } catch (_) {
      return '';
    }
  }

  Future<Insights> _read(int days, String me, String? postId) async {
    final from = Insights.dayOf(
      DateTime.now().subtract(Duration(days: days - 1)),
    );

    // 1. one post, or your posts of the period
    final mine = <Post>[];
    if (postId != null && postId.isNotEmpty) {
      final doc = await _db.collection('posts').doc(postId).get();
      if (doc.exists) mine.add(Post.fromDoc(doc));
    } else {
      final snap = await PostService.instance
          .userPostsQuery(me)
          .limit(maxPosts)
          .get();
      mine.addAll(
        snap.docs.map(Post.fromDoc).where((p) => !p.createdAt.isBefore(from)),
      );
    }

    // 2. who watched each of them, and when
    final insights = <PostInsight>[];
    for (final post in mine) {
      final views = await _db
          .collection('posts')
          .doc(post.id)
          .collection('views')
          .limit(maxViewsPerPost)
          .get();
      final ids = <String>[];
      final byDay = <DateTime, int>{};
      for (final d in views.docs) {
        final at = d.data()['at'];
        final when = at is Timestamp ? at.toDate() : null;
        if (when != null && when.isBefore(from)) continue;
        ids.add(d.id);
        if (when != null) {
          final day = Insights.dayOf(when);
          byDay[day] = (byDay[day] ?? 0) + 1;
        }
      }
      insights.add(
        PostInsight(
          post: post,
          views: ids.length,
          reach: ids.toSet().length,
          likes: post.likeCount,
          comments: post.commentCount,
          shares: post.shareCount,
          reposts: post.repostCount,
          viewerIds: ids,
          viewsByDay: byDay,
        ),
      );
    }

    // 3. your followers: who they are, and when they came
    final followers = await _db
        .collection('users')
        .doc(me)
        .collection('followers')
        .limit(1000)
        .get();
    final followerIds = <String>{};
    final joined = <String, DateTime?>{};
    for (final d in followers.docs) {
      followerIds.add(d.id);
      final at = d.data()['createdAt'];
      joined[d.id] = at is Timestamp ? at.toDate() : null;
    }

    // 4. who those viewers are (country and language), a few at a time
    final people = <String, AppUser>{};
    final wanted = <String>{
      for (final p in insights) ...p.viewerIds,
    }.take(maxPeople).toList();
    for (var i = 0; i < wanted.length; i += 10) {
      final part = wanted.sublist(
        i,
        i + 10 > wanted.length ? wanted.length : i + 10,
      );
      try {
        final docs = await _db
            .collection('users')
            .where(FieldPath.documentId, whereIn: part)
            .get();
        for (final d in docs.docs) {
          people[d.id] = AppUser.fromDoc(d);
        }
      } catch (_) {
        // one failed lookup must not break the whole screen
      }
    }

    final now = await UserService.instance.getUser(me);
    return Insights.build(
      days: days,
      posts: insights,
      people: people,
      followerIds: followerIds,
      followerJoined: joined,
      followersNow: now?.followersCount ?? followerIds.length,
    );
  }

  /// Called after a range change: nothing is kept, so it always re-reads.
  void clearCache() {
    // nothing is cached
  }
}
