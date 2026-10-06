import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';

/// "0:07" for 7 seconds.
String clockText(num seconds) {
  final v = seconds.round();
  return '${v ~/ 60}:${(v % 60).toString().padLeft(2, '0')}';
}

/// What a lane on the timeline stands for.
enum LaneKind { text, sticker }

/// A text or sticker on the timeline: a bar that shows when it is on screen.
class TimelineLane {
  const TimelineLane({
    required this.kind,
    required this.label,
    required this.from,
    required this.to,
    this.selected = false,
  });

  final LaneKind kind;
  final String label;

  /// Seconds in the video. [to] below 0 = until the end.
  final double from;
  final double to;
  final bool selected;
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
    this.lanes = const [],
    this.onLaneRange,
    this.onLaneTap,
  });

  /// Texts and stickers, one lane each (drag a bar to move it, drag its ends to change when
  /// it appears and disappears, tap it to select it).
  final List<TimelineLane> lanes;
  final void Function(int index, double from, double to)? onLaneRange;
  final ValueChanged<int>? onLaneTap;

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
  static const double stripH = 46;
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
          lanes: lanes,
          onLaneRange: onLaneRange,
          onLaneTap: onLaneTap,
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
    required this.lanes,
    required this.onLaneRange,
    required this.onLaneTap,
  });

  final List<TimelineLane> lanes;
  final void Function(int, double, double)? onLaneRange;
  final ValueChanged<int>? onLaneTap;
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
      TrimTimeline.handleW +
      (widget.total <= 0 ? 0 : sec / widget.total) * _usable;
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
    final laneRows = widget.lanes.length;
    final shownRows = laneRows > 3 ? 3 : laneRows;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _strip(xs, xe, stripTop),
                if (widget.audioLabel != null) _audioLane(xs, xe),
                if (laneRows > 0)
                  SizedBox(
                    height: shownRows * _laneH,
                    child: ListView(
                      key: const ValueKey('laneList'),
                      padding: EdgeInsets.zero,
                      physics: laneRows > 3
                          ? const ClampingScrollPhysics()
                          : const NeverScrollableScrollPhysics(),
                      children: [for (var i = 0; i < laneRows; i++) _lane(i)],
                    ),
                  ),
              ],
            ),
            // the playhead runs over the strip and every lane
            Positioned.fill(
              top: stripTop - 6,
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: ValueListenableBuilder<double>(
                    key: const ValueKey('playhead'),
                    valueListenable: widget.position,
                    builder: (_, p, _) {
                      final x = _x(
                        p.clamp(widget.start, widget.end).toDouble(),
                      );
                      return CustomPaint(painter: _PlayheadPainter(x));
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            TrimTimeline.handleW,
            4,
            TrimTimeline.handleW,
            0,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                clockText(widget.start),
                key: const ValueKey('trimStartText'),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
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
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static const double _laneH = 26;

  Widget _strip(double xs, double xe, double stripTop) {
    return GestureDetector(
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
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _RulerPainter(
                    total: widget.total,
                    left: TrimTimeline.handleW,
                    usable: _usable,
                  ),
                ),
              ),
            ),
            // frames: they never change while dragging, so they are painted once
            Positioned(
              left: TrimTimeline.handleW,
              right: TrimTimeline.handleW,
              top: stripTop,
              height: TrimTimeline.stripH,
              child: RepaintBoundary(
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
                                  cacheHeight: 96,
                                  gaplessPlayback: true,
                                  filterQuality: FilterQuality.low,
                                ),
                        ),
                    ],
                  ),
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
              child: const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.symmetric(
                      horizontal: BorderSide(color: AppTheme.volt, width: 3),
                    ),
                  ),
                ),
              ),
            ),
            _handle(
              const ValueKey('trimStartHandle'),
              xs - TrimTimeline.handleW,
              stripTop,
              true,
            ),
            _handle(const ValueKey('trimEndHandle'), xe, stripTop, false),
          ],
        ),
      ),
    );
  }

  Widget _audioLane(double xs, double xe) {
    return Padding(
      padding: EdgeInsets.only(
        left: xs,
        right: (widget.width - TrimTimeline.handleW - xe).clamp(
          0,
          widget.width,
        ),
        bottom: 4,
      ),
      child: Container(
        key: const ValueKey('audioLane'),
        height: 22,
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
    );
  }

  /// One text or sticker: a bar from when it appears to when it goes. The middle moves it,
  /// the two ends change the start and the end (half seconds).
  Widget _lane(int i) {
    final l = widget.lanes[i];
    final total = widget.total.toDouble();
    final from = l.from.clamp(0.0, total).toDouble();
    final to = (l.to < 0 ? total : l.to.clamp(0.0, total)).toDouble();
    final left = _x(from);
    final right = _x(to < from + 0.5 ? from + 0.5 : to);
    final color = l.kind == LaneKind.text ? Color(0xFF3D8BFF) : AppTheme.coral;
    return SizedBox(
      key: ValueKey('lane$i'),
      height: _laneH,
      child: Stack(
        children: [
          Positioned(
            left: left,
            width: (right - left).clamp(30.0, widget.width),
            top: 2,
            height: _laneH - 4,
            child: _LaneBar(
              key: ValueKey('laneBar$i'),
              label: l.label,
              icon: l.kind == LaneKind.text
                  ? Icons.title_rounded
                  : Icons.emoji_emotions_outlined,
              color: color,
              selected: l.selected,
              secondsPerPixel: widget.total <= 0 ? 0 : widget.total / _usable,
              from: from,
              to: to,
              total: total,
              onTap: () => widget.onLaneTap?.call(i),
              onRange: (f, t) => widget.onLaneRange?.call(i, f, t),
            ),
          ),
        ],
      ),
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
  _RulerPainter({
    required this.total,
    required this.left,
    required this.usable,
  });
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

class _PlayheadPainter extends CustomPainter {
  _PlayheadPainter(this.x);
  final double x;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;
    canvas.drawLine(Offset(x, 8), Offset(x, size.height), line);
    canvas.drawCircle(Offset(x, 5), 5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_PlayheadPainter old) => old.x != x;
}

/// The bar of one lane. Drag the middle to move it, the left or right end to resize it.
class _LaneBar extends StatefulWidget {
  const _LaneBar({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.secondsPerPixel,
    required this.from,
    required this.to,
    required this.total,
    required this.onTap,
    required this.onRange,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final double secondsPerPixel;
  final double from;
  final double to;
  final double total;
  final VoidCallback onTap;
  final void Function(double from, double to) onRange;

  @override
  State<_LaneBar> createState() => _LaneBarState();
}

enum _LaneDrag { move, left, right }

class _LaneBarState extends State<_LaneBar> {
  _LaneDrag _mode = _LaneDrag.move;
  double _from0 = 0;
  double _to0 = 0;
  double _dx = 0;
  static const double _edge = 16;
  static const double _step = 0.5;

  double _snap(double v) => (v / _step).round() * _step;

  void _down(DragDownDetails d, double width) {
    final x = d.localPosition.dx;
    _mode = x <= _edge
        ? _LaneDrag.left
        : (x >= width - _edge ? _LaneDrag.right : _LaneDrag.move);
    _from0 = widget.from;
    _to0 = widget.to;
    _dx = 0;
  }

  void _update(DragUpdateDetails d) {
    _dx += d.delta.dx;
    final dt = _dx * widget.secondsPerPixel;
    final total = widget.total;
    double f = _from0;
    double t = _to0;
    switch (_mode) {
      case _LaneDrag.move:
        final len = _to0 - _from0;
        f = _snap(_from0 + dt).clamp(0.0, total - len).toDouble();
        t = f + len;
      case _LaneDrag.left:
        f = _snap(_from0 + dt).clamp(0.0, _to0 - _step).toDouble();
      case _LaneDrag.right:
        t = _snap(_to0 + dt).clamp(_from0 + _step, total).toDouble();
    }
    if (f != widget.from || t != widget.to) {
      widget.onRange(f, t >= total - 0.01 ? -1 : t);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onHorizontalDragDown: (d) {
          _down(d, box.maxWidth);
          widget.onTap();
        },
        onHorizontalDragUpdate: _update,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: widget.selected ? 0.95 : 0.6),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: widget.selected ? Colors.white : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 12, color: Colors.white),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (widget.selected)
                const Icon(
                  Icons.drag_indicator_rounded,
                  size: 12,
                  color: Colors.white70,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
