import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import '../core/theme.dart';

/// Turns the player's coarse position reports (Android sends one about every half second)
/// into a smooth, steadily moving position: between two reports the position is advanced by
/// the time that passed (times the playback speed). Never runs backwards, except when the clip
/// really starts over or is searched.
class SmoothClock {
  Duration _base = Duration.zero;
  DateTime? _at;
  bool _playing = false;
  double _speed = 1;
  Duration _shown = Duration.zero;

  /// Feed every report of the player here.
  void sample(
    Duration position, {
    required bool playing,
    required double speed,
    required DateTime now,
  }) {
    final moved = position != _base;
    if (moved || playing != _playing || speed != _speed) {
      // keep the running estimate when nothing but a flag changed
      _base = moved ? position : estimate(now);
      _at = now;
    }
    _playing = playing;
    _speed = speed <= 0 ? 1 : speed;
  }

  /// Where the clip is now (not limited by the clip length; use [shown]).
  Duration estimate(DateTime now) {
    final at = _at;
    if (!_playing || at == null) return _base;
    final ms = now.difference(at).inMicroseconds * _speed;
    return _base + Duration(microseconds: ms.round());
  }

  /// The position to draw: smooth, limited to [total].
  Duration shown(DateTime now, Duration total) {
    var est = estimate(now);
    if (total > Duration.zero && est > total) est = total;
    final back = _shown - est;
    // small steps back are only the estimate being a little ahead: ignore them
    if (back < const Duration(milliseconds: 700)) {
      if (est > _shown) _shown = est;
    } else {
      _shown = est; // really went back (loop or search)
    }
    return _shown;
  }

  void reset(Duration position, DateTime now) {
    _base = position;
    _at = now;
    _shown = position;
  }
}

/// What the bar needs to know about the clip on screen.
abstract class ReelProgressSource {
  /// 0..1, smooth.
  double get fraction;

  /// 0..1, how much is downloaded (0 when unknown).
  double get buffered;
  Duration get position;
  Duration get total;

  /// Finger down on the bar: pause and follow it.
  void scrubStart();
  void scrub(double fraction);
  void scrubEnd();
  void dispose();
}

/// Link between a clip (video or photo) and the bar the screen draws above its dark gradient.
class ReelProgressHost extends ChangeNotifier {
  ReelProgressSource? source;
  bool _dead = false;

  void offer(ReelProgressSource s) {
    if (_dead) return;
    source = s;
    notifyListeners();
  }

  void withdraw(ReelProgressSource s) {
    if (_dead || source != s) return;
    source = null;
    // later, because a clip can be taken down in the middle of a frame
    scheduleMicrotask(() {
      if (!_dead) notifyListeners();
    });
  }

  @override
  void dispose() {
    _dead = true;
    super.dispose();
  }
}

class VideoProgressSource implements ReelProgressSource {
  VideoProgressSource(this.controller, {this.onScrubEnd}) {
    controller.addListener(_report);
    _report();
  }

  final VideoPlayerController controller;

  /// Called when the finger leaves the bar, to carry on playing.
  final VoidCallback? onScrubEnd;
  final SmoothClock _clock = SmoothClock();
  bool _scrubbing = false;
  bool _seeking = false;
  bool _dead = false;
  double _scrubTo = 0;
  Duration _lastTotal = Duration.zero;

  void _report() {
    if (_dead) return;
    final v = controller.value;
    _lastTotal = v.duration;
    _clock.sample(
      v.position,
      playing: v.isPlaying && !v.isBuffering,
      speed: v.playbackSpeed,
      now: DateTime.now(),
    );
  }

  @override
  Duration get total => _lastTotal;

  @override
  Duration get position => _scrubbing
      ? Duration(milliseconds: (total.inMilliseconds * _scrubTo).round())
      : _clock.shown(DateTime.now(), total);

  @override
  double get fraction {
    final t = total.inMilliseconds;
    if (t <= 0) return 0;
    if (_scrubbing) return _scrubTo;
    return (position.inMilliseconds / t).clamp(0.0, 1.0);
  }

  @override
  double get buffered {
    final t = total.inMilliseconds;
    if (t <= 0 || _dead) return 0;
    var end = 0;
    for (final r in controller.value.buffered) {
      if (r.end.inMilliseconds > end) end = r.end.inMilliseconds;
    }
    return (end / t).clamp(0.0, 1.0);
  }

  @override
  void scrubStart() {
    if (_dead) return;
    _scrubbing = true;
    _scrubTo = fraction;
    controller.pause();
  }

  Duration _at(double f) =>
      Duration(milliseconds: (total.inMilliseconds * f).round());

  @override
  void scrub(double f) {
    if (_dead || !_scrubbing) return;
    _scrubTo = f.clamp(0.0, 1.0);
    if (_seeking) return;
    _seeking = true;
    controller.seekTo(_at(_scrubTo)).whenComplete(() => _seeking = false);
  }

  @override
  void scrubEnd() {
    if (_dead) return;
    final to = _at(_scrubTo);
    _scrubbing = false;
    _clock.reset(to, DateTime.now());
    controller.seekTo(to);
    onScrubEnd?.call();
  }

  @override
  void dispose() {
    if (_dead) return;
    _dead = true;
    controller.removeListener(_report);
  }
}

class PhotoProgressSource implements ReelProgressSource {
  PhotoProgressSource(this.animation, {this.onScrubEnd});

  final AnimationController animation;
  final VoidCallback? onScrubEnd;
  bool _dead = false;

  @override
  double get fraction => _dead ? 0 : animation.value.clamp(0.0, 1.0);

  @override
  double get buffered => 0;

  @override
  Duration get total => animation.duration ?? Duration.zero;

  @override
  Duration get position =>
      Duration(milliseconds: (total.inMilliseconds * fraction).round());

  @override
  void scrubStart() {
    if (!_dead) animation.stop();
  }

  @override
  void scrub(double f) {
    if (!_dead) animation.value = f.clamp(0.0, 1.0);
  }

  @override
  void scrubEnd() {
    if (!_dead) onScrubEnd?.call();
  }

  @override
  void dispose() => _dead = true;
}

String formatClock(Duration d) {
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// The thin lime line at the bottom of a clip: smooth, always on top, touch to search.
class ReelProgressBar extends StatefulWidget {
  const ReelProgressBar({super.key, required this.host});
  final ReelProgressHost host;

  /// Height of the touch area (the line itself is thin).
  static const double hitHeight = 30;

  @override
  State<ReelProgressBar> createState() => _ReelProgressBarState();
}

class _ReelProgressBarState extends State<ReelProgressBar>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  late final Ticker _ticker = createTicker((_) => _frame.value++);
  bool _scrubbing = false;

  @override
  void initState() {
    super.initState();
    widget.host.addListener(_changed);
    _changed();
  }

  void _changed() {
    final has = widget.host.source != null;
    if (has && !_ticker.isActive) _ticker.start();
    if (!has && _ticker.isActive) _ticker.stop();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(ReelProgressBar old) {
    super.didUpdateWidget(old);
    if (old.host != widget.host) {
      old.host.removeListener(_changed);
      widget.host.addListener(_changed);
      _changed();
    }
  }

  @override
  void dispose() {
    widget.host.removeListener(_changed);
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  double _fractionAt(BuildContext context, Offset local) {
    final w = context.size?.width ?? 1;
    return w <= 0 ? 0 : (local.dx / w).clamp(0.0, 1.0);
  }

  void _start(Offset local) {
    final s = widget.host.source;
    if (s == null) return;
    setState(() => _scrubbing = true);
    s.scrubStart();
    s.scrub(_fractionAt(context, local));
  }

  void _move(Offset local) =>
      widget.host.source?.scrub(_fractionAt(context, local));

  void _end() {
    if (!_scrubbing) return;
    setState(() => _scrubbing = false);
    widget.host.source?.scrubEnd();
  }

  @override
  Widget build(BuildContext context) {
    final src = widget.host.source;
    if (src == null) return const SizedBox(height: ReelProgressBar.hitHeight);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (d) => _start(d.localPosition),
      onHorizontalDragUpdate: (d) => _move(d.localPosition),
      onHorizontalDragEnd: (_) => _end(),
      onHorizontalDragCancel: _end,
      onTapUp: (d) {
        _start(d.localPosition);
        _end();
      },
      child: SizedBox(
        height: ReelProgressBar.hitHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _BarPainter(
                  source: src,
                  scrubbing: _scrubbing,
                  repaint: _frame,
                ),
              ),
            ),
            if (_scrubbing)
              Positioned(
                left: 0,
                right: 0,
                bottom: ReelProgressBar.hitHeight + 2,
                child: ValueListenableBuilder<int>(
                  valueListenable: _frame,
                  builder: (_, _, _) => Center(
                    child: Text(
                      '${formatClock(src.position)} / ${formatClock(src.total)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        shadows: [Shadow(blurRadius: 8, color: Colors.black87)],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.source,
    required this.scrubbing,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final ReelProgressSource source;
  final bool scrubbing;

  @override
  void paint(Canvas canvas, Size size) {
    final h = scrubbing ? 7.0 : 4.0;
    final cy = size.height / 2;
    final track = RRect.fromLTRBR(
      0,
      cy - h / 2,
      size.width,
      cy + h / 2,
      Radius.circular(h / 2),
    );
    // dark halo so the line stays visible on bright pictures
    canvas.drawRRect(
      track.inflate(1),
      Paint()..color = const Color(0x55000000),
    );
    canvas.drawRRect(track, Paint()..color = const Color(0x55FFFFFF));
    canvas.save();
    canvas.clipRRect(track);
    final buffered = source.buffered * size.width;
    if (buffered > 0) {
      canvas.drawRect(
        Rect.fromLTRB(0, 0, buffered, size.height),
        Paint()..color = const Color(0x66FFFFFF),
      );
    }
    final played = source.fraction * size.width;
    canvas.drawRect(
      Rect.fromLTRB(0, 0, played, size.height),
      Paint()..color = AppTheme.volt,
    );
    canvas.restore();
    if (scrubbing) {
      canvas.drawCircle(
        Offset(played.clamp(0.0, size.width), cy),
        9,
        Paint()..color = Colors.white,
      );
      canvas.drawCircle(
        Offset(played.clamp(0.0, size.width), cy),
        6,
        Paint()..color = AppTheme.volt,
      );
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.source != source || old.scrubbing != scrubbing;
}
