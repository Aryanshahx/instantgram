import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:video_player/video_player.dart';

import '../../shared/models/post.dart';
import 'net_quality.dart';
import 'video_cache.dart';

/// "Instant" loading, like Instagram Reels:
///  * photos/covers of what comes next are downloaded to the disk cache
///    before you scroll there (images show at once)
///  * the next 2 videos are opened in the background, so the first frames
///    are already buffered when you swipe (video starts at once)
class MediaPrefetch {
  MediaPrefetch._();
  static final MediaPrefetch instance = MediaPrefetch._();

  /// Tests switch this off (no network).
  static bool disabled = false;

  static const int _remember = 400;
  final LinkedHashSet<String> _done = LinkedHashSet<String>();

  /// Puts an image in the same disk cache NetImage uses.
  void image(String url) {
    if (disabled || url.isEmpty || !url.startsWith('http')) return;
    if (!_done.add(url)) return;
    if (_done.length > _remember) _done.remove(_done.first);
    unawaited(
      DefaultCacheManager()
          .getSingleFile(url)
          .then<void>((_) {}, onError: (Object _) => _done.remove(url)),
    );
  }

  /// Covers + photos of a post (first [items] items).
  void post(Post p, {int items = 2}) {
    if (disabled) return;
    image(p.coverUrl);
    for (final m in p.items.take(items)) {
      image(m.coverUrl);
    }
  }

  /// Downloads the start of a video to the disk cache (v0.8).
  void video(String url, {int? bytes}) {
    if (disabled || url.isEmpty || !url.startsWith('http')) return;
    unawaited(VideoCache.instance.prefetch(url, bytes: bytes));
  }

  /// Images + first video of the next posts/clips.
  /// [videos] players are opened, [diskVideos] are downloaded a bit.
  void ahead(
    List<Post> list,
    int index, {
    int images = 3,
    int videos = 2,
    int diskVideos = 3,
    bool Function(Post p)? mixWithOthers,
  }) {
    if (disabled) return;
    for (var k = 1; k <= diskVideos && index + k < list.length; k++) {
      final p = list[index + k];
      for (final m in p.items.take(2)) {
        if (m.isVideo) video(NetQuality.urlFor(m));
      }
    }
    for (var k = 1; k <= images && index + k < list.length; k++) {
      post(list[index + k]);
    }
    for (var k = 1; k <= videos && index + k < list.length; k++) {
      final p = list[index + k];
      final first = p.items.isEmpty ? null : p.items.first;
      if (first != null && first.isVideo) {
        VideoPool.instance.prefetch(
          NetQuality.urlFor(first),
          mixWithOthers: mixWithOthers?.call(p) ?? false,
        );
      }
    }
  }
}

/// A video player that was opened in the background.
class PooledVideo {
  PooledVideo(this.controller, this.ready);
  final VideoPlayerController controller;

  /// Completes when the player is ready (first frames buffered).
  final Future<void> ready;
}

/// Keeps a few ready-to-play videos (max [maxSize]) so the next clip
/// starts instantly. Players are handed over with [take]; whoever takes a
/// player owns it and must dispose it.
class VideoPool {
  VideoPool._();
  static final VideoPool instance = VideoPool._();

  static int maxSize = 3;

  /// Tests switch this off (no real players).
  static bool disabled = false;

  final LinkedHashMap<String, PooledVideo> _pool =
      LinkedHashMap<String, PooledVideo>();

  String _key(String url, bool mix) => '${mix ? 1 : 0}|$url';

  @visibleForTesting
  int get size => _pool.length;

  bool has(String url, {bool mixWithOthers = false}) =>
      _pool.containsKey(_key(url, mixWithOthers));

  /// Opens [url] in the background (does nothing if already there).
  void prefetch(String url, {bool mixWithOthers = false}) {
    if (disabled || url.isEmpty || !url.startsWith('http')) return;
    final key = _key(url, mixWithOthers);
    if (_pool.containsKey(key)) {
      // move to the end = most recent
      _pool[key] = _pool.remove(key)!;
      return;
    }
    final c = VideoCache.instance.controller(url, mixWithOthers: mixWithOthers);
    final ready = c.initialize();
    // never leave an unhandled error behind
    unawaited(ready.then<void>((_) {}, onError: (Object _) {}));
    _pool[key] = PooledVideo(c, ready);
    _trim();
  }

  /// Gives back a player that was just watched, so swiping back to it
  /// starts at once (v0.8). The pool owns it now.
  void keep(
    String url,
    VideoPlayerController c, {
    bool mixWithOthers = false,
  }) {
    final key = _key(url, mixWithOthers);
    if (disabled || !c.value.isInitialized || c.value.hasError ||
        _pool.containsKey(key)) {
      c.dispose();
      return;
    }
    c.pause();
    c.setVolume(0);
    c.setPlaybackSpeed(1);
    c.seekTo(Duration.zero);
    _pool[key] = PooledVideo(c, Future<void>.value());
    _trim();
  }

  /// Takes the ready player for [url] (or null). The caller owns it.
  PooledVideo? take(String url, {bool mixWithOthers = false}) =>
      _pool.remove(_key(url, mixWithOthers));

  void _trim() {
    while (_pool.length > maxSize) {
      final oldest = _pool.keys.first;
      _drop(_pool.remove(oldest)!);
    }
  }

  void _drop(PooledVideo v) {
    v.ready.then<void>(
      (_) => v.controller.dispose(),
      onError: (Object _) => v.controller.dispose(),
    );
  }

  /// Frees everything (e.g. when the app goes to the background).
  void clear() {
    for (final v in _pool.values) {
      _drop(v);
    }
    _pool.clear();
  }
}
