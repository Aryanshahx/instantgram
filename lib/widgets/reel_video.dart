import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/theme.dart';
import '../models/post.dart';
import '../services/clip_cache.dart';

/// App-wide sound switch for clips.
class ReelAudio {
  static final ValueNotifier<bool> muted = ValueNotifier<bool>(false);
}

/// Our own video player UI on top of the native player (ExoPlayer):
/// full-bleed video, tap to pause, loop, thin lime progress line, spinner.
/// Streams from the bucket, which supports seeking (HTTP Range).
class ReelVideo extends StatefulWidget {
  const ReelVideo({
    super.key,
    required this.post,
    required this.play,
    this.fit,
    this.progressBottom = 0,
    this.onDoubleTap,
  });

  final Post post;

  /// true = playing (when not paused by the user); false = loaded but paused.
  final bool play;

  /// null = automatic (cover for portrait clips, contain for landscape).
  final BoxFit? fit;

  /// Space under the progress line (to stay above the floating nav bar).
  final double progressBottom;

  /// Double tap (the clips screen uses it for "like"). A heart pops up under the finger.
  final VoidCallback? onDoubleTap;

  @override
  State<ReelVideo> createState() => _ReelVideoState();
}

class _ReelVideoState extends State<ReelVideo> {
  VideoPlayerController? _c;
  bool _ready = false;
  bool _failed = false;
  bool _userPaused = false;
  bool _flash = false;
  bool _fast = false; // finger held down: 2x speed
  Offset _tapAt = Offset.zero;
  Offset? _burstAt;
  int _burstId = 0;
  int _gen = 0; // bumped whenever a newer start replaces an older one
  DateTime? _playingSince;

  @override
  void initState() {
    super.initState();
    if (widget.play) _playingSince = DateTime.now();
    ReelAudio.muted.addListener(_applyVolume);
    _init(first: true);
  }

  /// The downloaded copy of this clip, if there is (or soon will be) one.
  ///  * Already on the phone: use it.
  ///  * Being downloaded in the background: wait for it. A clip that is only being preloaded
  ///    waits as long as it takes; once it is on screen it waits at most 2.5 s, then the
  ///    download is stopped and the clip streams directly with the full connection.
  ///  * Nothing coming and on screen now: stream it.
  Future<File?> _localCopy(int gen) async {
    final url = widget.post.videoUrl;
    final cache = ClipCache.instance;
    final have = cache.cached(url);
    if (have != null) return have;
    var pending = cache.inFlight(url);
    if (pending == null) {
      if (widget.play) return null;
      pending = cache.prefetch(url);
    }
    while (true) {
      if (!mounted || gen != _gen) return null;
      var finished = false;
      pending.whenComplete(() => finished = true);
      await Future.any<void>([
        pending,
        Future<void>.delayed(const Duration(milliseconds: 150)),
      ]);
      if (!mounted || gen != _gen) return null;
      final f = cache.cached(url);
      if (f != null) return f;
      if (finished) return null;
      if (widget.play && _giveUp(cache, url)) {
        cache.cancel(url, streaming: true);
        return null;
      }
    }
  }

  /// A clip that is on screen waits for its download only while that is quicker than
  /// starting to stream it.
  bool _giveUp(ClipCache cache, String url) {
    final waited = DateTime.now().difference(_playingSince ?? DateTime.now());
    final p = cache.progress(url);
    if (p == null) return true; // nothing is coming
    if (waited > const Duration(seconds: 14)) return true;
    if (!p.started) return waited > const Duration(milliseconds: 1500);
    final eta = p.eta;
    if (eta == null) return waited > const Duration(seconds: 3);
    return waited > const Duration(milliseconds: 1200) &&
        eta > const Duration(seconds: 7);
  }

  Future<VideoPlayerController> _open(File? local) async {
    if (local != null) {
      final c = VideoPlayerController.file(local);
      try {
        await c.initialize();
        return c;
      } catch (_) {
        await c.dispose();
        try {
          await local.delete(); // damaged copy: download it again next time
        } catch (_) {}
      }
    }
    final c = VideoPlayerController.networkUrl(Uri.parse(widget.post.videoUrl));
    await c.initialize();
    return c;
  }

  Future<void> _init({bool first = false}) async {
    final gen = ++_gen;
    if (!first) {
      setState(() {
        _failed = false;
        _ready = false;
      });
    }
    final old = _c;
    _c = null;
    await old?.dispose();
    try {
      final local = await _localCopy(gen);
      if (!mounted || gen != _gen) return;
      final c = await _open(local);
      if (!mounted || gen != _gen) {
        await c.dispose();
        return;
      }
      await c.setLooping(true);
      await c.setVolume(ReelAudio.muted.value ? 0 : 1);
      if (!mounted || gen != _gen) {
        await c.dispose();
        return;
      }
      setState(() {
        _c = c;
        _ready = true;
      });
      _sync();
    } catch (_) {
      if (mounted && gen == _gen) setState(() => _failed = true);
    }
  }

  void _applyVolume() {
    _c?.setVolume(ReelAudio.muted.value ? 0 : 1);
  }

  void _sync() {
    final c = _c;
    if (c == null || !_ready) return;
    if (widget.play && !_userPaused) {
      c.play();
    } else {
      c.pause();
    }
  }

  @override
  void didUpdateWidget(ReelVideo old) {
    super.didUpdateWidget(old);
    if (old.post.videoUrl != widget.post.videoUrl) {
      _init();
      return;
    }
    if (old.play != widget.play) {
      if (widget.play) {
        _userPaused = false;
        _playingSince = DateTime.now();
        _c?.seekTo(Duration.zero);
      } else if (_fast) {
        _fast = false;
        _c?.setPlaybackSpeed(1.0);
      }
      _sync();
    }
  }

  @override
  void dispose() {
    ReelAudio.muted.removeListener(_applyVolume);
    _gen++;
    _c?.dispose();
    super.dispose();
  }

  void _toggle() {
    if (!_ready) return;
    setState(() {
      _userPaused = !_userPaused;
      _flash = true;
    });
    _sync();
    Future<void>.delayed(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _flash = false);
    });
  }

  void _setFast(bool v) {
    if (_fast == v) return;
    setState(() => _fast = v);
    _c?.setPlaybackSpeed(v ? 2.0 : 1.0);
  }

  void _doubleTap() {
    final id = ++_burstId;
    setState(() => _burstAt = _tapAt);
    widget.onDoubleTap?.call();
    Future<void>.delayed(const Duration(milliseconds: 800), () {
      if (mounted && _burstId == id) setState(() => _burstAt = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final thumb = widget.post.thumbnailUrl;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      onDoubleTapDown: (d) => _tapAt = d.localPosition,
      onDoubleTap: widget.onDoubleTap == null ? null : _doubleTap,
      onLongPressStart: (_) => _setFast(true),
      onLongPressEnd: (_) => _setFast(false),
      onLongPressCancel: () => _setFast(false),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          if (!_ready && thumb.isNotEmpty)
            CachedNetworkImage(
              imageUrl: thumb,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => const SizedBox.shrink(),
            ),
          if (_ready && c != null)
            ClipRect(
              child: FittedBox(
                fit:
                    widget.fit ??
                    (c.value.aspectRatio < 0.9 ? BoxFit.cover : BoxFit.contain),
                child: SizedBox(
                  width: c.value.size.width,
                  height: c.value.size.height,
                  child: VideoPlayer(c),
                ),
              ),
            ),
          if (!_failed)
            if (c == null)
              const _Spinner()
            else
              ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: c,
                builder: (_, v, _) => (!_ready || v.isBuffering)
                    ? const _Spinner()
                    : const SizedBox.shrink(),
              ),
          Center(
            child: AnimatedOpacity(
              opacity: (_flash || (_userPaused && _ready)) ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: Icon(
                _userPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                color: Colors.white,
                size: 72,
                shadows: const [Shadow(blurRadius: 14, color: Colors.black54)],
              ),
            ),
          ),
          if (_burstAt != null)
            Positioned(
              left: _burstAt!.dx - 56,
              top: _burstAt!.dy - 56,
              child: IgnorePointer(
                child: TweenAnimationBuilder<double>(
                  key: ValueKey(_burstId),
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 750),
                  builder: (_, t, _) => Opacity(
                    opacity: (t < 0.6 ? 1.0 : (1 - t) / 0.4).clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale:
                          0.5 +
                          Curves.elasticOut.transform(t.clamp(0, 1)) * 0.7,
                      child: const Icon(
                        Icons.favorite_rounded,
                        size: 112,
                        color: Color(0xFFFF3B5C),
                        shadows: [
                          Shadow(blurRadius: 18, color: Colors.black45),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (_fast)
            Positioned(
              top: MediaQuery.of(context).padding.top + 62,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '2x',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                          ),
                        ),
                        SizedBox(width: 4),
                        Icon(
                          Icons.fast_forward_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (_failed)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: Colors.white70,
                    size: 40,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Could not play this clip',
                    style: TextStyle(color: Colors.white70),
                  ),
                  TextButton(
                    onPressed: () => _init(),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          if (_ready && c != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: widget.progressBottom,
              child: VideoProgressIndicator(
                c,
                allowScrubbing: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                colors: VideoProgressColors(
                  playedColor: AppTheme.volt,
                  bufferedColor: Colors.white24,
                  backgroundColor: Colors.white12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const Center(
    child: SizedBox(
      width: 34,
      height: 34,
      child: CircularProgressIndicator(strokeWidth: 3, color: AppTheme.volt),
    ),
  );
}
