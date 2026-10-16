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

  void start() {
    if (_sub != null) return;
    _sub = PostRepository.instance
        .recent(type: Post.clip, limit: limit)
        .listen(_onClips, onError: (Object _) {});
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

  void stop() {
    _sub?.cancel();
    _sub = null;
    _latest = null;
    _warmed = false;
  }
}
