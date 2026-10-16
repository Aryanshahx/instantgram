import 'package:cloud_firestore/cloud_firestore.dart';

import '../../shared/models/post.dart';
import '../post/data/post_repository.dart' show ViewSource, kAgeGroups;

/// Analytics numbers made from view docs. Only totals — never who watched.
/// [PostInsights.from] = one post / clip.
/// [PostInsights.fromMany] = your whole account (Dashboard).
class PostInsights {
  PostInsights._({
    required this.post,
    required this.postCount,
    required this.views,
    required this.reach,
    required this.detailed,
    required this.followerViews,
    required this.countries,
    required this.ages,
    required this.sources,
    required this.languages,
    required this.watchSamples,
    required this.avgWatchMs,
    required this.completionRate,
    required this.watchDocs,
    required this.engagementRate,
    required this.timeline,
    required this.hourly,
    required this.likes,
    required this.comments,
    required this.shares,
    required this.reposts,
    required this.saves,
    required this.hasVideo,
  });

  /// The post (null = account totals).
  final Post? post;

  /// How many posts/clips are counted.
  final int postCount;

  /// All views, also repeat views by the same account.
  final int views;

  /// Accounts that saw it (one each).
  final int reach;

  /// View docs with details (from v0.5.0 on).
  final int detailed;
  final int followerViews;
  int get nonFollowerViews => detailed - followerViews;

  /// Sorted, biggest first: (key, count).
  final List<(String, int)> countries;

  /// In age order (13-17 ... 55+), only groups with views.
  final List<(String, int)> ages;
  final List<(String, int)> sources;
  final List<(String, int)> languages;

  /// Videos only.
  final int watchSamples;
  final double avgWatchMs;

  /// 0..1 part of viewers who watched to the end.
  final double completionRate;

  /// v0.20: views that have watch data (completion is made from these).
  final int watchDocs;

  /// Views per day (or per hour when the post is younger than 2 days).
  final List<(DateTime, int)> timeline;
  final bool hourly;

  final int likes;
  final int comments;
  final int shares;
  final int reposts;
  final int saves;
  final bool hasVideo;

  bool get isAccount => post == null;
  int get interactions => likes + comments + shares + reposts + saves;

  /// v0.20: interactions per account reached, 0..1 (was over 100%).
  final double engagementRate;

  /// Average interactions per post.
  double get interactionsPerPost =>
      postCount == 0 ? 0 : interactions / postCount;

  factory PostInsights.from(
    Post post,
    List<Map<String, dynamic>> docs, {
    DateTime? now,
  }) => _build([post], [docs], post: post, now: now);

  /// Account totals over many posts. [docs] = view docs of each post
  /// (same order as [posts]).
  factory PostInsights.fromMany(
    List<Post> posts,
    List<List<Map<String, dynamic>>> docs, {
    DateTime? now,
  }) => _build(posts, docs, now: now);

  static DateTime? _date(Object? v) {
    if (v is Timestamp) return v.toDate();
    if (v is DateTime) return v;
    return null;
  }

  static List<(String, int)> _sorted(Map<String, int> m) {
    final list = m.entries.map((e) => (e.key, e.value)).toList()
      ..sort((a, b) {
        final c = b.$2.compareTo(a.$2);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    return list;
  }

  static PostInsights _build(
    List<Post> posts,
    List<List<Map<String, dynamic>>> docsPerPost, {
    Post? post,
    DateTime? now,
  }) {
    final n = now ?? DateTime.now();
    var views = 0, followers = 0, watchN = 0, watchSum = 0, done = 0;
    var videoDocs = 0, detailed = 0, maxReach = 0, reachSum = 0;
    final viewers = <String>{};
    final countries = <String, int>{};
    final ages = <String, int>{};
    final sources = <String, int>{};
    final langs = <String, int>{};
    final dates = <DateTime>[];
    var likes = 0, comments = 0, shares = 0, reposts = 0, saves = 0;
    var hasVideo = false;
    for (var k = 0; k < posts.length; k++) {
      final p = posts[k];
      final docs = k < docsPerPost.length
          ? docsPerPost[k]
          : const <Map<String, dynamic>>[];
      likes += p.likesCount;
      comments += p.commentsCount;
      shares += p.sharesCount;
      reposts += p.repostsCount;
      saves += p.savesCount < 0 ? 0 : p.savesCount;
      if (p.hasVideo) hasVideo = true;
      // watch time: one post = all its docs; account = video posts only
      final countWatch = post != null || p.hasVideo;
      var pViews = 0;
      for (final d in docs) {
        final c = d['count'];
        pViews += c is num && c >= 1 ? c.toInt() : 1;
        final id = d['_id'];
        if (id is String && id.isNotEmpty) viewers.add(id);
        if (d['follower'] == true) followers++;
        final country = d['country'];
        if (country is String && country.isNotEmpty) {
          countries[country.toUpperCase()] =
              (countries[country.toUpperCase()] ?? 0) + 1;
        }
        final age = d['ageGroup'];
        if (age is String && kAgeGroups.contains(age)) {
          ages[age] = (ages[age] ?? 0) + 1;
        }
        final src = ViewSource.normalize(
          d['source'] is String ? d['source'] as String : '',
        );
        sources[src] = (sources[src] ?? 0) + 1;
        final lang = d['language'];
        if (lang is String && lang.isNotEmpty) {
          langs[lang] = (langs[lang] ?? 0) + 1;
        }
        if (countWatch) {
          final w = d['watchMs'];
          if (w is num && w > 0) {
            watchN++;
            watchSum += w.toInt();
          }
          // v0.20: only views with watch data count (old docs had none)
          if (w is num || d['completed'] is bool) {
            videoDocs++;
            if (d['completed'] == true) done++;
          }
        }
        final at = _date(d['createdAt']);
        if (at != null) dates.add(at);
      }
      detailed += docs.length;
      final pReach = docs.length > p.viewsCount ? docs.length : p.viewsCount;
      if (pReach > maxReach) maxReach = pReach;
      reachSum += pReach;
      views += pViews < pReach ? pReach : pViews;
    }

    // one post: accounts = its viewers. Account: different people across
    // all posts (at least the best single post).
    final int reach;
    if (post != null) {
      reach = maxReach;
    } else {
      reach = viewers.length > maxReach ? viewers.length : maxReach;
    }

    // v0.20: engagement = interactions / accounts reached of each post
    // (account: added up, so older posts count too). Everyone who liked
    // saw it. Never over 100%.
    var base = post != null ? reach : (reachSum > reach ? reachSum : reach);
    if (likes > base) base = likes;
    final interactions = likes + comments + shares + reposts + saves;
    final engagement = base == 0
        ? 0.0
        : (interactions / base).clamp(0.0, 1.0).toDouble();

    // timeline: hours for young posts, else days (max 30 buckets)
    final start = posts.isEmpty
        ? n
        : posts.map((p) => p.createdAt).reduce((a, b) => a.isBefore(b) ? a : b);
    final age = n.difference(start);
    final hourly = age.inHours < 48;
    final step = hourly ? const Duration(hours: 1) : const Duration(days: 1);
    DateTime floor(DateTime t) => hourly
        ? DateTime(t.year, t.month, t.day, t.hour)
        : DateTime(t.year, t.month, t.day);
    final first = floor(start);
    var buckets = hourly ? age.inHours + 1 : age.inDays + 1;
    if (buckets < 1) buckets = 1;
    final shown = buckets > 30 ? 30 : buckets;
    final from = buckets > 30 ? floor(n).subtract(step * (shown - 1)) : first;
    final counts = List<int>.filled(shown, 0);
    for (final t in dates) {
      final i = floor(t).difference(from).inMinutes ~/ step.inMinutes;
      if (i >= 0 && i < shown) counts[i]++;
    }
    final timeline = [
      for (var i = 0; i < shown; i++) (from.add(step * i), counts[i]),
    ];

    return PostInsights._(
      post: post,
      postCount: posts.length,
      views: views,
      reach: reach,
      detailed: detailed,
      followerViews: followers,
      countries: _sorted(countries),
      ages: [
        for (final g in kAgeGroups)
          if ((ages[g] ?? 0) > 0) (g, ages[g]!),
      ],
      sources: _sorted(sources),
      languages: _sorted(langs),
      watchSamples: watchN,
      avgWatchMs: watchN == 0 ? 0 : watchSum / watchN,
      completionRate: videoDocs == 0
          ? 0
          : (done / videoDocs).clamp(0.0, 1.0).toDouble(),
      watchDocs: videoDocs,
      engagementRate: engagement,
      timeline: timeline,
      hourly: hourly,
      likes: likes,
      comments: comments,
      shares: shares,
      reposts: reposts,
      saves: saves,
      hasVideo: hasVideo,
    );
  }
}
