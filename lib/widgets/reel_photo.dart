import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/music.dart';
import '../models/post.dart';
import '../services/music_player.dart';
import 'reel_touch.dart';

/// A photo clip: the picture is shown for its length (5 s or more) with a slow zoom while its
/// music plays, then it starts over. Same touch controls as a video (tap = pause, double tap =
/// like, hold and slide = volume).
class ReelPhoto extends StatefulWidget {
  const ReelPhoto({
    super.key,
    required this.post,
    required this.play,
    this.progressBottom = 0,
    this.onDoubleTap,
  });

  final Post post;
  final bool play;
  final double progressBottom;
  final VoidCallback? onDoubleTap;

  @override
  State<ReelPhoto> createState() => _ReelPhotoState();
}

class _ReelPhotoState extends State<ReelPhoto>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: Duration(seconds: widget.post.videoDuration.clamp(5, 60)),
  );
  late final ImageProvider _image = CachedNetworkImageProvider(
    widget.post.imageUrl,
    maxWidth: 1600,
  );
  MusicPlayer? _music;
  bool _loaded = false;
  bool _failed = false;
  bool _userPaused = false;
  bool _flash = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    ReelAudio.muted.addListener(_applyVolume);
    ReelAudio.volume.addListener(_applyVolume);
    _anim.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        _music?.restart();
        _anim.forward(from: 0);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  Future<void> _load() async {
    try {
      await precacheImage(_image, context);
      final track = musicById(widget.post.musicId);
      if (track != null) {
        final m = MusicPlayer(track);
        await m.init();
        if (!mounted) {
          await m.dispose();
          return;
        }
        _music = m;
      }
      if (!mounted) return;
      setState(() => _loaded = true);
      _applyVolume();
      _sync();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _applyVolume() {
    _music?.setVolume(ReelAudio.effective * widget.post.musicVolume);
  }

  void _sync() {
    if (!_loaded) return;
    if (widget.play && !_userPaused) {
      if (!_anim.isAnimating) _anim.forward();
      _music?.play();
    } else {
      _anim.stop();
      _music?.pause();
    }
  }

  @override
  void didUpdateWidget(ReelPhoto old) {
    super.didUpdateWidget(old);
    if (old.play != widget.play) {
      if (widget.play) {
        _userPaused = false;
        _anim.value = 0;
        _music?.restart();
      }
      _sync();
    }
  }

  @override
  void dispose() {
    ReelAudio.muted.removeListener(_applyVolume);
    ReelAudio.volume.removeListener(_applyVolume);
    _anim.dispose();
    _music?.dispose();
    super.dispose();
  }

  void _toggle() {
    if (!_loaded) return;
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
    return ReelTouch(
      onTap: _toggle,
      onDoubleTap: widget.onDoubleTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          if (_loaded) ...[
            // soft blurred copy fills the space around the picture
            ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
              child: Opacity(
                opacity: 0.55,
                child: Image(image: _image, fit: BoxFit.cover),
              ),
            ),
            AnimatedBuilder(
              animation: _anim,
              builder: (_, child) => Transform.scale(
                scale: 1 + 0.07 * Curves.easeInOut.transform(_anim.value),
                child: child,
              ),
              child: Image(image: _image, fit: BoxFit.contain),
            ),
          ] else if (!_failed)
            const Center(
              child: SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: AppTheme.volt,
                ),
              ),
            ),
          if (_failed)
            const Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: Colors.white54,
                size: 48,
              ),
            ),
          Center(
            child: AnimatedOpacity(
              opacity: (_flash || (_userPaused && _loaded)) ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: Icon(
                _userPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                color: Colors.white,
                size: 72,
                shadows: const [Shadow(blurRadius: 14, color: Colors.black54)],
              ),
            ),
          ),
          if (_loaded)
            Positioned(
              left: 0,
              right: 0,
              bottom: widget.progressBottom + 8,
              child: AnimatedBuilder(
                animation: _anim,
                builder: (_, _) => LinearProgressIndicator(
                  value: _anim.value,
                  minHeight: 3,
                  color: AppTheme.volt,
                  backgroundColor: Colors.white12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
