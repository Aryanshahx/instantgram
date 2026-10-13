import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import '../../core/theme/app_colors.dart';

/// Video progress bar that moves smoothly (every frame, not every half
/// second) and can be dragged or tapped to jump in the video.
/// [startMs] / [endMs] = trimmed part of the video (0 = whole video).
class SmoothSeekBar extends StatefulWidget {
  const SmoothSeekBar({
    super.key,
    required this.controller,
    this.startMs = 0,
    this.endMs = 0,
    this.height = 18,
  });

  final VideoPlayerController controller;
  final int startMs;
  final int endMs;

  /// Touch area height (the visible bar is thinner).
  final double height;

  @override
  State<SmoothSeekBar> createState() => _SmoothSeekBarState();
}

class _SmoothSeekBarState extends State<SmoothSeekBar>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onFrame);
  int _lastPos = 0;
  DateTime _lastAt = DateTime.now();
  double _shown = 0;
  double? _drag; // 0..1 while dragging
  DateTime _lastSeek = DateTime(2000);

  VideoPlayerController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onValue);
    _onValue();
  }

  @override
  void didUpdateWidget(covariant SmoothSeekBar old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onValue);
      widget.controller.addListener(_onValue);
      _shown = 0;
      _onValue();
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onValue);
    _ticker.dispose();
    super.dispose();
  }

  void _onValue() {
    final v = _c.value;
    final pos = v.position.inMilliseconds;
    if (pos != _lastPos) {
      _lastPos = pos;
      _lastAt = DateTime.now();
    }
    final run = v.isInitialized && v.isPlaying;
    if (run && !_ticker.isActive) _ticker.start();
    if (!run && _ticker.isActive) {
      _ticker.stop();
      if (mounted) setState(() {});
    }
  }

  void _onFrame(Duration _) {
    if (mounted) setState(() {});
  }

  (int, int) get _range {
    final total = _c.value.duration.inMilliseconds;
    final start = widget.startMs.clamp(0, total);
    final end = (widget.endMs > start ? widget.endMs : total).clamp(
      start,
      total,
    );
    return (start, end);
  }

  /// Where the video is now (0..1), guessed between position updates.
  double _fraction() {
    final v = _c.value;
    if (!v.isInitialized) return 0;
    final (start, end) = _range;
    final len = end - start;
    if (len <= 0) return 0;
    var pos = _lastPos.toDouble();
    if (v.isPlaying) {
      pos +=
          DateTime.now().difference(_lastAt).inMilliseconds * v.playbackSpeed;
    }
    final f = ((pos - start) / len).clamp(0.0, 1.0);
    // never step back a little (looks shaky); big jumps = seek / loop
    if (f < _shown && _shown - f < 300 / len) return _shown;
    return f;
  }

  double _bufferedFraction() {
    final v = _c.value;
    if (!v.isInitialized || v.buffered.isEmpty) return 0;
    final (start, end) = _range;
    final len = end - start;
    if (len <= 0) return 0;
    final b = v.buffered.last.end.inMilliseconds;
    return ((b - start) / len).clamp(0.0, 1.0);
  }

  void _seekTo(double f, {bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastSeek).inMilliseconds < 150) return;
    _lastSeek = now;
    final (start, end) = _range;
    final ms = (start + (end - start) * f.clamp(0.0, 1.0)).round();
    _c.seekTo(Duration(milliseconds: ms));
    _lastPos = ms;
    _lastAt = now;
    _shown = f;
  }

  double _fracAt(double dx, double width) =>
      width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final playing = _drag ?? (_shown = _fraction());
    final buffered = _bufferedFraction();
    final active = _drag != null;
    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        key: const ValueKey('seek-bar'),
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) =>
            _seekTo(_fracAt(d.localPosition.dx, box.maxWidth), force: true),
        onHorizontalDragStart: (d) =>
            setState(() => _drag = _fracAt(d.localPosition.dx, box.maxWidth)),
        onHorizontalDragUpdate: (d) {
          final f = _fracAt(d.localPosition.dx, box.maxWidth);
          setState(() => _drag = f);
          _seekTo(f); // live preview while dragging
        },
        onHorizontalDragEnd: (_) {
          final f = _drag;
          if (f != null) _seekTo(f, force: true);
          setState(() => _drag = null);
        },
        onHorizontalDragCancel: () => setState(() => _drag = null),
        child: SizedBox(
          height: widget.height,
          width: double.infinity,
          child: CustomPaint(
            painter: _BarPainter(
              played: playing,
              buffered: buffered,
              active: active,
            ),
          ),
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.played,
    required this.buffered,
    required this.active,
  });

  final double played;
  final double buffered;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final h = active ? 5.0 : 3.0;
    final y = size.height - h - (active ? 4 : 0);
    final r = Radius.circular(h / 2);
    final back = Paint()..color = const Color(0xFF3A3D44);
    final buf = Paint()..color = const Color(0xFF6B6E75);
    final play = Paint()..color = AppColors.lime;
    canvas.drawRRect(RRect.fromLTRBR(0, y, size.width, y + h, r), back);
    if (buffered > 0) {
      canvas.drawRRect(
        RRect.fromLTRBR(0, y, size.width * buffered, y + h, r),
        buf,
      );
    }
    canvas.drawRRect(
      RRect.fromLTRBR(0, y, size.width * played, y + h, r),
      play,
    );
    if (active) {
      canvas.drawCircle(Offset(size.width * played, y + h / 2), 7, play);
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.played != played || old.buffered != buffered || old.active != active;
}
