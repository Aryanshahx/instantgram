import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/theme.dart';
import '../models/post.dart';

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
  });

  final Post post;

  /// true = playing (when not paused by the user); false = loaded but paused.
  final bool play;

  /// null = automatic (cover for portrait clips, contain for landscape).
  final BoxFit? fit;

  /// Space under the progress line (to stay above the floating nav bar).
  final double progressBottom;

  @override
  State<ReelVideo> createState() => _ReelVideoState();
}

class _ReelVideoState extends State<ReelVideo> {
  VideoPlayerController? _c;
  bool _ready = false;
  bool _failed = false;
  bool _userPaused = false;
  bool _flash = false;

  @override
  void initState() {
    super.initState();
    ReelAudio.muted.addListener(_applyVolume);
    _init(first: true);
  }

  Future<void> _init({bool first = false}) async {
    if (!first) {
      setState(() {
        _failed = false;
        _ready = false;
      });
    }
    final old = _c;
    final c = VideoPlayerController.networkUrl(Uri.parse(widget.post.videoUrl));
    _c = c;
    await old?.dispose();
    try {
      await c.initialize();
      if (!mounted || _c != c) return;
      await c.setLooping(true);
      await c.setVolume(ReelAudio.muted.value ? 0 : 1);
      setState(() => _ready = true);
      _sync();
    } catch (_) {
      if (mounted && _c == c) setState(() => _failed = true);
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
        _c?.seekTo(Duration.zero);
      }
      _sync();
    }
  }

  @override
  void dispose() {
    ReelAudio.muted.removeListener(_applyVolume);
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

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final thumb = widget.post.thumbnailUrl;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
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
          if (c != null && !_failed)
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: c,
              builder: (_, v, _) {
                final busy = !_ready || v.isBuffering;
                return busy
                    ? const Center(
                        child: SizedBox(
                          width: 34,
                          height: 34,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: AppTheme.volt,
                          ),
                        ),
                      )
                    : const SizedBox.shrink();
              },
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
