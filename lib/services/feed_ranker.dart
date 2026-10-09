import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../core/media_url.dart';
import '../models/post.dart';
import 'feed_signals.dart';
import 'safety_service.dart';

/// Why a post is in the For you feed (v1.34 shows it in "Why am I seeing this?").
enum FeedReason { following, close, trending, discover, yours }

/// Orders posts for "For you" (Home) and Clips:
///
///   score = closeness x (likes + 2 comments + 3 shares + 2 super hearts + 1) / (hours + 2)^1.5
///
/// Posts already seen sink. Home mixes in about 1 post in 6 from accounts I do not follow;
/// Clips fill each 10 with 7 from people I follow or watch, 2 trending, 1 new.
class FeedRanker {
  FeedRanker._();
  static final FeedRanker instance = FeedRanker._();

  DateTime Function() now = DateTime.now;

  /// Every 6th Home post is from somebody I do not follow (when there is one).
  static const int discoverEvery = 6;

  /// Clips, per 10: F = following / close, T = trending, N = new.
  static const String clipPattern = 'FFTFFNFTFF';

  final Map<String, FeedReason> _reasons = {};

  FeedReason? reasonFor(String postId) => _reasons[postId];

  Set<String> get _following => SafetyService.instance.following;
  String get _me => SafetyService.instance.me;

  bool _isFollowed(Post p) =>
      p.authorId == _me || _following.contains(p.authorId);

  double closeness(String uid) {
    if (uid == _me) return 1.0;
    final base = _following.contains(uid) ? 1.5 : 0.6;
    final pts = Closeness.instance.scoreOf(uid);
    return base + math.min(2.0, 0.4 * math.log(1 + pts));
  }

  double engagement(Post p) =>
      p.likeCount +
      2.0 * p.commentCount +
      3.0 * p.shareCount +
      2.0 * p.superCount +
      1;

  /// Already seen posts go down (watched clips most).
  double seenFactor(Post p) {
    final pct = WatchLog.instance.percent(p.id);
    if (pct == null) return 1;
    if (p.isClip) return pct >= 80 ? 0.1 : (pct > 0 ? 0.3 : 0.5);
    return 0.25;
  }

  double score(Post p) {
    final hours = math.max(0, now().difference(p.createdAt).inMinutes / 60);
    return closeness(p.authorId) *
        engagement(p) /
        math.pow(hours + 2, 1.5) *
        seenFactor(p);
  }

  List<Post> _sorted(Iterable<Post> l) {
    final scored = [for (final p in l) (p, score(p))];
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final s in scored) s.$1];
  }

  FeedReason _reasonOf(Post p, Set<String> trending) {
    if (p.authorId == _me) return FeedReason.yours;
    if (trending.contains(p.id)) return FeedReason.trending;
    if (_following.contains(p.authorId)) {
      return Closeness.instance.scoreOf(p.authorId) >= 5
          ? FeedReason.close
          : FeedReason.following;
    }
    return Closeness.instance.scoreOf(p.authorId) >= 5
        ? FeedReason.close
        : FeedReason.discover;
  }

  /// Home "For you": one loaded page in order.
  List<Post> arrangeHome(List<Post> page, {Set<String> trending = const {}}) {
    final mine = _sorted(page.where(_isFollowed));
    final others = _sorted(page.where((p) => !_isFollowed(p)));
    final out = <Post>[];
    var a = 0, b = 0;
    while (a < mine.length || b < others.length) {
      final slot = out.length + 1;
      final wantOther = slot % discoverEvery == 0 || a >= mine.length;
      if (wantOther && b < others.length) {
        out.add(others[b++]);
      } else if (a < mine.length) {
        out.add(mine[a++]);
      } else {
        out.add(others[b++]);
      }
    }
    for (final p in out) {
      _reasons[p.id] = _reasonOf(p, trending);
    }
    return out;
  }

  /// Clips: 7 of 10 from people I follow or watch a lot, 2 trending, 1 new.
  List<Post> arrangeClips(List<Post> page, {Set<String> trending = const {}}) {
    final t = <Post>[
      for (final id in trending) ...page.where((p) => p.id == id),
    ];
    final rest = page.where((p) => !trending.contains(p.id)).toList();
    final f = _sorted(
      rest.where(
        (p) => _isFollowed(p) || Closeness.instance.scoreOf(p.authorId) >= 3,
      ),
    );
    final fs = f.toSet();
    // new: the newest from everybody else, not seen yet first
    final n = rest.where((p) => !fs.contains(p)).toList()
      ..sort((x, y) {
        final sx = WatchLog.instance.seen(x.id) ? 1 : 0;
        final sy = WatchLog.instance.seen(y.id) ? 1 : 0;
        if (sx != sy) return sx - sy;
        return y.createdAt.compareTo(x.createdAt);
      });
    final pools = {'F': f, 'T': t, 'N': n};
    final at = {'F': 0, 'T': 0, 'N': 0};
    const fallback = {'F': 'FTN', 'T': 'TFN', 'N': 'NTF'};
    final out = <Post>[];
    while (out.length < page.length) {
      final want = clipPattern[out.length % clipPattern.length];
      var took = false;
      for (final k in fallback[want]!.split('')) {
        if (at[k]! < pools[k]!.length) {
          out.add(pools[k]![at[k]!]);
          at[k] = at[k]! + 1;
          took = true;
          break;
        }
      }
      if (!took) break;
    }
    for (final p in out) {
      _reasons[p.id] = _reasonOf(p, trending);
    }
    return out;
  }
}

/// Tests replace where trending posts come from.
Future<List<Post>> Function(bool clips)? debugTrendingSource;

/// The trending list the signer works out (config/trending, at most hourly).
class TrendingService {
  TrendingService._();
  static final TrendingService instance = TrendingService._();

  static const Duration stale = Duration(minutes: 70);

  List<String> _posts = const [];
  List<String> _clips = const [];
  DateTime? _readAt;
  Future<void>? _reading;

  Future<void> _read() async {
    final fresh =
        _readAt != null &&
        DateTime.now().difference(_readAt!) < const Duration(minutes: 20);
    if (fresh) return;
    await (_reading ??= _doRead().whenComplete(() => _reading = null));
  }

  Future<void> _doRead() async {
    try {
      final d = await FirebaseFirestore.instance
          .collection('config')
          .doc('trending')
          .get();
      final m = d.data() ?? const {};
      List<String> ids(Object? v) => v is List
          ? [
              for (final x in v)
                if (x is String) x,
            ]
          : const [];
      _posts = ids(m['posts']);
      _clips = ids(m['clips']);
      _readAt = DateTime.now();
      final at = m['at'];
      final when = at is Timestamp ? at.toDate() : null;
      if (when == null || DateTime.now().difference(when) > stale) {
        unawaited(_askSigner());
      }
    } catch (_) {
      // no trending this time
    }
  }

  /// Asks the signer to work the list out again (it does so at most once an hour).
  Future<void> _askSigner() async {
    try {
      if (!mediaServerConfigured) return;
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken() ?? '';
      await Dio().post<dynamic>(
        '$mediaApiBase/trending',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      _readAt = null; // read the new list next time
    } catch (_) {}
  }

  /// Up to [max] trending posts (or clips) I may see.
  Future<List<Post>> load({required bool clips, int max = 20}) async {
    final hook = debugTrendingSource;
    if (hook != null) return hook(clips);
    await _read();
    final ids = (clips ? _clips : _posts).take(max).toList();
    if (ids.isEmpty) return const [];
    try {
      final col = FirebaseFirestore.instance.collection('posts');
      final found = <String, Post>{};
      for (var i = 0; i < ids.length; i += 10) {
        final part = ids.sublist(i, math.min(i + 10, ids.length));
        final snap = await col.where(FieldPath.documentId, whereIn: part).get();
        for (final d in snap.docs) {
          found[d.id] = Post.fromDoc(d);
        }
      }
      return [
        for (final id in ids)
          if (found[id] case final p?)
            if (!p.profileOnly && SafetyService.instance.canSee(p)) p,
      ];
    } catch (_) {
      return const [];
    }
  }
}
