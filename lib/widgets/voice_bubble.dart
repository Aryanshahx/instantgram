import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/media_url.dart';

/// Play button, progress bar and time of one voice message.
class VoiceBubble extends StatefulWidget {
  const VoiceBubble({
    super.key,
    required this.url,
    required this.seconds,
    required this.color,
  });

  final String url;
  final int seconds;
  final Color color;

  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble> {
  VideoPlayerController? _c;
  bool _loading = false;
  bool _failed = false;

  @override
  void dispose() {
    _c?.removeListener(_tick);
    _c?.dispose();
    super.dispose();
  }

  void _tick() {
    final c = _c;
    if (c == null || !mounted) return;
    final v = c.value;
    if (v.isInitialized && !v.isPlaying && v.position >= v.duration) {
      c.seekTo(Duration.zero);
      c.pause();
    }
    setState(() {});
  }

  Future<void> _toggle() async {
    if (_loading) return;
    var c = _c;
    if (c == null) {
      if (widget.url.isEmpty) {
        setState(() => _failed = true);
        return;
      }
      setState(() {
        _loading = true;
        _failed = false;
      });
      try {
        c = VideoPlayerController.networkUrl(
          Uri.parse(widget.url),
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
        );
        await c.initialize();
        c.addListener(_tick);
        _c = c;
      } catch (_) {
        await c?.dispose();
        if (mounted) {
          setState(() {
            _loading = false;
            _failed = true;
          });
        }
        return;
      }
      if (mounted) setState(() => _loading = false);
    }
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      if (c.value.position >= c.value.duration) await c.seekTo(Duration.zero);
      await c.play();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final v = c?.value;
    final total =
        (v != null && v.isInitialized && v.duration.inMilliseconds > 0)
        ? v.duration
        : Duration(seconds: widget.seconds);
    final pos = v?.position ?? Duration.zero;
    final playing = v?.isPlaying ?? false;
    final frac = total.inMilliseconds == 0
        ? 0.0
        : (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    final shown = playing || pos > Duration.zero ? total - pos : total;
    return SizedBox(
      width: 220,
      child: Row(
        children: [
          GestureDetector(
            key: const ValueKey('voicePlay'),
            onTap: _toggle,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.16),
                shape: BoxShape.circle,
              ),
              child: _loading
                  ? Padding(
                      padding: const EdgeInsets.all(10),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: widget.color,
                      ),
                    )
                  : Icon(
                      _failed
                          ? Icons.error_outline_rounded
                          : playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: widget.color,
                    ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: frac,
                    minHeight: 5,
                    color: widget.color,
                    backgroundColor: widget.color.withValues(alpha: 0.22),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  _failed
                      ? 'Could not play'
                      : formatDuration((shown.inMilliseconds / 1000).ceil()),
                  style: TextStyle(
                    color: widget.color.withValues(alpha: 0.75),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
