import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';

/// "0:07" for 7 seconds.
String clockText(num seconds) {
  final v = seconds.round();
  return '${v ~/ 60}:${(v % 60).toString().padLeft(2, '0')}';
}

/// The timeline of the clip editor: a strip of frames, a ruler with seconds, two handles that
/// snap to whole seconds (drag them to trim), a playhead (drag anywhere on the strip to
/// scrub) and, when a sound is chosen, a lane under the strip that shows it.
class TrimTimeline extends StatelessWidget {
  const TrimTimeline({
    super.key,
    required this.total,
    required this.start,
    required this.end,
    required this.position,
    required this.frames,
    required this.onRange,
    required this.onSeek,
    this.maxSeconds,
    this.audioLabel,
  });

  /// Length of the whole video in seconds.
  final int total;

  /// The kept part, in whole seconds.
  final double start;
  final double end;

  /// Where the video is playing (seconds).
  final ValueListenable<double> position;

  /// Pictures along the video (null = not loaded yet).
  final List<Uint8List?> frames;

  /// New range (whole seconds) and whether the start handle was the one that moved.
  final void Function(double start, double end, bool startMoved) onRange;
  final ValueChanged<double> onSeek;
  final int? maxSeconds;
  final String? audioLabel;

  static const double handleW = 16;
  static const double stripH = 54;
  static const double rulerH = 16;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        return _Body(
          width: width,
          total: total,
          start: start,
          end: end,
          position: position,
          frames: frames,
          onRange: onRange,
          onSeek: onSeek,
          maxSeconds: maxSeconds,
          audioLabel: audioLabel,
        );
      },
    );
  }
}

class _Body extends StatefulWidget {
  const _Body({
    required this.width,
    required this.total,
    required this.start,
    required this.end,
    required this.position,
    required this.frames,
    required this.onRange,
    required this.onSeek,
    required this.maxSeconds,
    required this.audioLabel,
  });

  final double width;
  final int total;
  final double start;
  final double end;
  final ValueListenable<double> position;
  final List<Uint8List?> frames;
  final void Function(double, double, bool) onRange;
  final ValueChanged<double> onSeek;
  final int? maxSeconds;
  final String? audioLabel;

  @override
  State<_Body> createState() => _BodyState();
}

enum _Drag { none, start, end, seek }

class _BodyState extends State<_Body> {
  _Drag _drag = _Drag.none;

  double get _usable => widget.width - TrimTimeline.handleW * 2;
  double _x(double sec) =>
      TrimTimeline.handleW + (widget.total <= 0 ? 0 : sec / widget.total) * _usable;
  double _sec(double x) => widget.total <= 0
      ? 0
      : ((x - TrimTimeline.handleW) / _usable * widget.total).clamp(
          0.0,
          widget.total.toDouble(),
        );

  void _begin(double x) {
    final xs = _x(widget.start);
    final xe = _x(widget.end);
    final ds = (x - (xs - TrimTimeline.handleW / 2)).abs();
    final de = (x - (xe + TrimTimeline.handleW / 2)).abs();
    const reach = 26.0;
    if (ds <= reach && ds <= de) {
      _drag = _Drag.start;
    } else if (de <= reach) {
      _drag = _Drag.end;
    } else {
      _drag = _Drag.seek;
    }
    _move(x);
  }

  void _move(double x) {
    final cap = widget.maxSeconds;
    switch (_drag) {
      case _Drag.start:
        var s = _sec(x).roundToDouble();
        s = s.clamp(0, widget.end - 1).toDouble();
        if (cap != null && widget.end - s > cap) s = widget.end - cap;
        if (s != widget.start) widget.onRange(s, widget.end, true);
      case _Drag.end:
        var e = _sec(x).roundToDouble();
        e = e.clamp(widget.start + 1, widget.total.toDouble()).toDouble();
        if (cap != null && e - widget.start > cap) e = widget.start + cap;
        if (e != widget.end) widget.onRange(widget.start, e, false);
      case _Drag.seek:
        widget.onSeek(_sec(x).clamp(widget.start, widget.end).toDouble());
      case _Drag.none:
    }
  }

  @override
  Widget build(BuildContext context) {
    final keep = (widget.end - widget.start).round();
    final xs = _x(widget.start);
    final xe = _x(widget.end);
    final stripTop = TrimTimeline.rulerH;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          key: const ValueKey('trimTimeline'),
          behavior: HitTestBehavior.opaque,
          // down = pick what is being moved (a tap on the strip also scrubs to that spot)
          onHorizontalDragDown: (d) => _begin(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => _move(d.localPosition.dx),
          onHorizontalDragEnd: (_) => _drag = _Drag.none,
          onHorizontalDragCancel: () => _drag = _Drag.none,
          child: SizedBox(
            height: TrimTimeline.rulerH + TrimTimeline.stripH + 4,
            width: widget.width,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // ruler
                Positioned.fill(
                  child: CustomPaint(
                    painter: _RulerPainter(
                      total: widget.total,
                      left: TrimTimeline.handleW,
                      usable: _usable,
                    ),
                  ),
                ),
                // frames
                Positioned(
                  left: TrimTimeline.handleW,
                  right: TrimTimeline.handleW,
                  top: stripTop,
                  height: TrimTimeline.stripH,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Row(
                      children: [
                        for (final f in widget.frames)
                          Expanded(
                            child: f == null
                                ? const ColoredBox(color: Color(0xFF1B1F2A))
                                : Image.memory(
                                    f,
                                    fit: BoxFit.cover,
                                    height: TrimTimeline.stripH,
                                    gaplessPlayback: true,
                                  ),
                          ),
                      ],
                    ),
                  ),
                ),
                // dimmed parts that are cut away
                Positioned(
                  left: TrimTimeline.handleW,
                  width: (xs - TrimTimeline.handleW).clamp(0, widget.width),
                  top: stripTop,
                  height: TrimTimeline.stripH,
                  child: const ColoredBox(color: Color(0xB3000000)),
                ),
                Positioned(
                  left: xe,
                  width: (widget.width - TrimTimeline.handleW - xe).clamp(
                    0,
                    widget.width,
                  ),
                  top: stripTop,
                  height: TrimTimeline.stripH,
                  child: const ColoredBox(color: Color(0xB3000000)),
                ),
                // frame around the kept part
                Positioned(
                  left: xs,
                  width: (xe - xs).clamp(0, widget.width),
                  top: stripTop,
                  height: TrimTimeline.stripH,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.symmetric(
                          horizontal: BorderSide(
                            color: AppTheme.volt,
                            width: 3,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                _handle(const ValueKey('trimStartHandle'), xs - TrimTimeline.handleW, stripTop, true),
                _handle(const ValueKey('trimEndHandle'), xe, stripTop, false),
                // playhead
                ValueListenableBuilder<double>(
                  valueListenable: widget.position,
                  builder: (_, p, _) {
                    final x = _x(p.clamp(widget.start, widget.end).toDouble());
                    return Positioned(
                      key: const ValueKey('playhead'),
                      left: x - 1,
                      top: stripTop - 6,
                      child: IgnorePointer(
                        child: Column(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                              transform: Matrix4.translationValues(-4, 0, 0),
                            ),
                            Container(
                              width: 2,
                              height: TrimTimeline.stripH + 2,
                              color: Colors.white,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        if (widget.audioLabel != null)
          Padding(
            padding: EdgeInsets.only(
              left: xs,
              right: (widget.width - TrimTimeline.handleW - xe).clamp(0, widget.width),
              top: 2,
            ),
            child: Container(
              key: const ValueKey('audioLane'),
              height: 20,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: AppTheme.violet.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(Icons.music_note_rounded, size: 12, color: Colors.white),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.audioLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            TrimTimeline.handleW,
            6,
            TrimTimeline.handleW,
            0,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                clockText(widget.start),
                key: const ValueKey('trimStartText'),
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
              ),
              Text(
                '${keep}s'
                '${widget.maxSeconds != null ? '  \u00b7  max ${widget.maxSeconds}s' : ''}',
                key: const ValueKey('trimKeepText'),
                style: const TextStyle(
                  color: AppTheme.volt,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
              Text(
                clockText(widget.end),
                key: const ValueKey('trimEndText'),
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _handle(Key key, double left, double top, bool isStart) {
    return Positioned(
      left: left,
      top: top,
      width: TrimTimeline.handleW,
      height: TrimTimeline.stripH,
      child: IgnorePointer(
        child: Container(
          key: key,
          decoration: BoxDecoration(
            color: AppTheme.volt,
            borderRadius: BorderRadius.horizontal(
              left: Radius.circular(isStart ? 8 : 0),
              right: Radius.circular(isStart ? 0 : 8),
            ),
          ),
          child: Icon(
            isStart ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
            size: 16,
            color: AppTheme.ink,
          ),
        ),
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({required this.total, required this.left, required this.usable});
  final int total;
  final double left;
  final double usable;

  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    final paint = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    // a tick every second when there is room, otherwise every 5 or 10
    var step = 1;
    while (usable / (total / step) < 6 && step < total) {
      step = step < 5 ? 5 : step * 2;
    }
    final labelEvery = step == 1 ? 5 : step;
    for (var s = 0; s <= total; s += step) {
      final x = left + s / total * usable;
      final major = s % labelEvery == 0;
      canvas.drawLine(Offset(x, major ? 4 : 8), Offset(x, 13), paint);
      if (major && s != total) {
        final tp = TextPainter(
          text: TextSpan(
            text: clockText(s),
            style: const TextStyle(color: Colors.white54, fontSize: 9),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        if (x + tp.width + 3 < size.width) tp.paint(canvas, Offset(x + 3, -1));
      }
    }
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.total != total || old.usable != usable;
}
