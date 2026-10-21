import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

import 'stickers.dart';
import '../models/post.dart';
import 'styled_text.dart';

/// v0.12: one text / sticker drawn on a video frame [frameWidth] wide.
/// Same look in the editor and when watching.
class OverlayView extends StatelessWidget {
  const OverlayView({
    super.key,
    required this.overlay,
    required this.frameWidth,
  });

  final VideoOverlay overlay;
  final double frameWidth;

  @override
  Widget build(BuildContext context) {
    final o = overlay;
    final fs = (o.size * frameWidth).clamp(6.0, 2000.0);
    if (o.isSticker && StickerPack.isPack(o.text)) {
      // v0.13: built-in sticker picture (size = width)
      return StickerImage(text: o.text, width: o.size * frameWidth);
    }
    return StyledText(
      spec: TextSpec.ofOverlay(o),
      fontSize: fs,
      maxWidth: o.isSticker ? frameWidth * 4 : frameWidth * 0.9,
    );
  }
}

/// v0.0.1: turns [child] by [rotation] (radians) around its middle.
Widget turned(double rotation, Widget child) =>
    rotation == 0 ? child : Transform.rotate(angle: rotation, child: child);

/// Places [child] with its center at ([x], [y]) (0..1) of the box.
class OverlayPlace extends StatelessWidget {
  const OverlayPlace({
    super.key,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.child,
  });

  final double x;
  final double y;
  final double width;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: x * width,
      top: y * height,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: child,
      ),
    );
  }
}

/// v0.12: the texts / stickers of a video at the current moment.
/// Put it on top of the video, in a box with the video's shape.
class VideoOverlayLayer extends StatelessWidget {
  const VideoOverlayLayer({
    super.key,
    required this.overlays,
    required this.controller,
  });

  final List<VideoOverlay> overlays;
  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    if (overlays.isEmpty) return const SizedBox.shrink();
    final timed = overlays.any((o) => o.startMs > 0 || o.endMs > 0);
    Widget layer(int ms) => LayoutBuilder(
      builder: (context, box) => Stack(
        clipBehavior: Clip.none,
        children: [
          for (final o in overlays)
            if (o.visibleAt(ms))
              OverlayPlace(
                x: o.x,
                y: o.y,
                width: box.maxWidth,
                height: box.maxHeight,
                child: turned(
                  o.rotation,
                  OverlayView(overlay: o, frameWidth: box.maxWidth),
                ),
              ),
        ],
      ),
    );
    return IgnorePointer(
      child: timed
          ? ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: controller,
              builder: (context, v, _) => layer(v.position.inMilliseconds),
            )
          : layer(0),
    );
  }
}

/// v0.12: plays the voice over of a video in time with the video.
/// Follows the video: plays / pauses / jumps with it.
class VoiceTrack {
  VoiceTrack(this.edits);

  /// Tests: never touch the audio plugin.
  static bool disabled = false;

  final VideoEdits edits;
  AudioPlayer? _player;
  VideoPlayerController? _c;
  bool _loaded = false;
  bool _loading = false;
  bool _muted = false;
  DateTime _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);

  bool get active => edits.hasVoice && !disabled;

  void attach(VideoPlayerController c) {
    if (identical(c, _c)) return;
    detach();
    _c = c;
    if (!active) return;
    c.addListener(_sync);
    _sync();
  }

  void detach() {
    _c?.removeListener(_sync);
    _c = null;
    _player?.pause();
  }

  /// App mute (not the "original sound off" edit).
  set muted(bool m) {
    if (_muted == m) return;
    _muted = m;
    _sync();
  }

  Future<void> _load() async {
    if (_loaded || _loading) return;
    _loading = true;
    try {
      final p = _player ??= AudioPlayer(
        handleInterruptions: false,
        handleAudioSessionActivation: false,
      );
      final src = edits.voiceSource;
      if (src.startsWith('http')) {
        await p.setUrl(src);
      } else {
        await p.setFilePath(src);
      }
      _loaded = true;
      _sync();
    } catch (e) {
      debugPrint('voice over: $e');
    } finally {
      _loading = false;
    }
  }

  /// Where the voice should be now (ms into the voice), or null = silent.
  static int? voiceAt(VideoEdits e, int videoPosMs) {
    final played = VideoTime.playedAt(videoPosMs, e.trimStartMs, e.cuts);
    final rel = played - e.voiceStartMs;
    if (rel < 0 || rel >= e.voiceDurMs) return null;
    return rel;
  }

  void _sync() {
    final c = _c;
    if (c == null || !active || !c.value.isInitialized) return;
    if (!_loaded) {
      unawaited(_load());
      return;
    }
    final p = _player!;
    final rel = voiceAt(edits, c.value.position.inMilliseconds);
    final play = c.value.isPlaying && !_muted && rel != null;
    if (!play) {
      if (p.playing) p.pause();
      return;
    }
    final now = DateTime.now();
    if (!p.playing) {
      p.seek(Duration(milliseconds: rel));
      _lastSeek = now;
      p.play(); // don't await: completes when playback stops
      return;
    }
    // the video reports its position about twice a second: only fix
    // big differences, and not too often
    final drift = (p.position.inMilliseconds - rel).abs();
    if (drift > 900 && now.difference(_lastSeek).inMilliseconds > 1500) {
      p.seek(Duration(milliseconds: rel));
      _lastSeek = now;
    }
  }

  void dispose() {
    detach();
    _player?.dispose();
    _player = null;
  }
}
