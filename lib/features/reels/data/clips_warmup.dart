import 'dart:async';

import '../../../core/services/hyper_feed.dart';
import '../../../core/services/media_prefetch.dart';
import '../../../shared/models/post.dart';
import '../../post/data/post_repository.dart';
import '../../../core/services/net_quality.dart';

/// Keeps the Clips list loaded in the background from app start and gets
/// the first clip ready, so the Clips tab opens and plays instantly.
class ClipsWarmup {
  ClipsWarmup._();
  static final ClipsWarmup instance = ClipsWarmup._();

  static const int limit = 50;

  StreamSubscription<List<Post>>? _sub;
  List<Post>? _latest;
  bool _warmed = false;

  /// Last known clips list (null = not loaded yet).
  List<Post>? get latest => _latest;

  /// How many app screens use it (see [stop]).
  int _users = 0;

  final List<Completer<List<Post>>> _waiting = [];

  void start() {
    _users++;
    if (_sub != null) return;
    // new account / account switch: the last list gets the first clip
    // ready at once, the fresh list follows
    final old = _latest;
    if (old != null && old.isNotEmpty) _warm(old);
    _sub = PostRepository.instance
        .recent(type: Post.clip, limit: limit)
        .listen(_onClips, onError: (Object _) {});
  }

  /// The clips list as soon as there is one (at once when known; empty when
  /// not running or after [wait]).
  Future<List<Post>> first({Duration wait = const Duration(seconds: 4)}) {
    final l = _latest;
    if (l != null) return Future.value(l);
    if (_sub == null) return Future.value(const <Post>[]);
    final c = Completer<List<Post>>();
    _waiting.add(c);
    return c.future.timeout(
      wait,
      onTimeout: () {
        _waiting.remove(c);
        return const <Post>[];
      },
    );
  }

  void _onClips(List<Post> fresh) {
    // v0.19 Hyper Intelligence: ranked (same order as the Clips screen,
    // so the clip made ready here is the first one shown)
    final list = HyperFeed.instance.ordered(
      'clips',
      fresh,
      mode: FeedMode.clips,
    );
    _latest = list;
    for (final c in _waiting) {
      if (!c.isCompleted) c.complete(list);
    }
    _waiting.clear();
    _warm(list);
  }

  void _warm(List<Post> list) {
    if (_warmed || list.isEmpty) return;
    _warmed = true;
    final first = list.first;
    for (final p in list.take(3)) {
      MediaPrefetch.instance.post(p);
    }
    if (first.items.isNotEmpty && first.items.first.isVideo) {
      VideoPool.instance.prefetch(
        NetQuality.urlFor(first.items.first),
        mixWithOthers: first.hasMusic,
      );
    }
  }

  /// Keeps the last list (clips are the same for every account), so the
  /// next account's Clips tab and feed open with it at once.
  void stop() {
    if (_users > 0) _users--;
    if (_users > 0) return;
    _sub?.cancel();
    _sub = null;
    _warmed = false;
    for (final c in _waiting) {
      if (!c.isCompleted) c.complete(const <Post>[]);
    }
    _waiting.clear();
  }
}
