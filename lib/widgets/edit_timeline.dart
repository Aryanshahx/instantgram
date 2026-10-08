import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// One timed item under the clip (a text, a sticker or a caption).
class EditLane {
  const EditLane({
    required this.label,
    required this.from,
    required this.to,
    this.icon = Icons.text_fields_rounded,
    this.selected = false,
  });

  final String label;
  final IconData icon;

  /// Seconds of the video; [to] < 0 = until the end.
  final double from;
  final double to;
  final bool selected;
}

/// The timeline of the edit screen, the way video editors do it: the white playhead stays
/// in the middle and the tracks slide under it. Drag sideways to move through the clip,
/// pinch to zoom, tap a track to select it and drag its white handles to trim.
///
/// Times are seconds of the original video. The kept part runs from [start] to [end]; the
/// rest of the clip is shown dimmed.
class EditTimeline extends StatefulWidget {
  const EditTimeline({
    super.key,
    required this.total,
    required this.start,
    required this.end,
    required this.position,
    this.frames = const [],
    this.maxSeconds,
    this.muted = false,
    this.videoSelected = false,
    this.audioLabel,
    this.voice = false,
    this.lanes = const [],
    this.onSeekStart,
    this.onSeek,
    this.onSeekEnd,
    this.onRange,
    this.onVideoTap,
    this.onMuteTap,
    this.onAddClip,
    this.onAudioTap,
    this.onAddAudio,
    this.onVoiceTap,
    this.onLaneTap,
    this.onLaneRange,
    this.onAddText,
    this.height = 232,
  });

  final int total;
  final double start;
  final double end;
  final ValueListenable<double> position;
  final List<Uint8List?> frames;
  final int? maxSeconds;
  final bool muted;
  final bool videoSelected;

  /// The song's name (null = no song: an "Add audio" track is shown).
  final String? audioLabel;

  /// A voiceover was recorded.
  final bool voice;
  final List<EditLane> lanes;

  final VoidCallback? onSeekStart;
  final ValueChanged<double>? onSeek;
  final VoidCallback? onSeekEnd;

  /// New kept part: start, end, and whether the start handle moved.
  final void Function(double start, double end, bool startMoved)? onRange;
  final VoidCallback? onVideoTap;
  final VoidCallback? onMuteTap;
  final VoidCallback? onAddClip;
  final VoidCallback? onAudioTap;
  final VoidCallback? onAddAudio;
  final VoidCallback? onVoiceTap;
  final ValueChanged<int>? onLaneTap;
  final void Function(int lane, double from, double to)? onLaneRange;
  final VoidCallback? onAddText;
  final double height;

  /// Room for the time marks above the tracks.
  static const double rulerHeight = 30;
  static const double videoHeight = 60;
  static const double trackHeight = 46;
  static const double gap = 8;

  /// Points per second at zoom 1.
  static const double basePps = 48;

  @override
  State<EditTimeline> createState() => _EditTimelineState();
}

class _EditTimelineState extends State<EditTimeline> {
  double _pps = EditTimeline.basePps;

  // pinch: two fingers, tracked raw so sideways dragging keeps working with one
  final Map<int, Offset> _fingers = {};
  double? _pinchFrom;
  double _ppsFrom = EditTimeline.basePps;
  bool _scrubbing = false;

  /// Room before 0 s, so the first handle can be grabbed.
  static const double _pad = 24;
  static const double _minPps = 12;
  static const double _maxPps = 260;

  double get _len => widget.total.toDouble();

  // ------------------------------------------------------------- gestures

  void _down(PointerDownEvent e) {
    _fingers[e.pointer] = e.localPosition;
    if (_fingers.length == 2) {
      final p = _fingers.values.toList();
      _pinchFrom = (p[0] - p[1]).distance;
      _ppsFrom = _pps;
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_fingers.containsKey(e.pointer)) return;
    _fingers[e.pointer] = e.localPosition;
    final from = _pinchFrom;
    if (_fingers.length >= 2 && from != null && from > 8) {
      final p = _fingers.values.toList();
      final d = (p[0] - p[1]).distance;
      setState(() => _pps = (_ppsFrom * d / from).clamp(_minPps, _maxPps));
    }
  }

  void _up(PointerEvent e) {
    _fingers.remove(e.pointer);
    if (_fingers.length < 2) _pinchFrom = null;
  }

  void _dragStart(DragStartDetails _) {
    if (_fingers.length > 1) return;
    _scrubbing = true;
    widget.onSeekStart?.call();
  }

  void _dragUpdate(DragUpdateDetails d) {
    if (!_scrubbing || _fingers.length > 1) return;
    // finger to the left = later in the clip
    final t = (widget.position.value - d.delta.dx / _pps).clamp(0.0, _len);
    widget.onSeek?.call(t);
  }

  void _dragEnd([DragEndDetails? _]) {
    if (!_scrubbing) return;
    _scrubbing = false;
    widget.onSeekEnd?.call();
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: GestureDetector(
        key: const ValueKey('editTimeline'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _dragStart,
        onHorizontalDragUpdate: _dragUpdate,
        onHorizontalDragEnd: _dragEnd,
        onHorizontalDragCancel: _dragEnd,
        child: SizedBox(
          height: widget.height,
          child: LayoutBuilder(
            builder: (context, c) => _tracks(context, c.maxWidth),
          ),
        ),
      ),
    );
  }

  Widget _tracks(BuildContext context, double width) {
    final center = width / 2;
    final contentW = _len * _pps;
    final fullW = _pad * 2 + contentW + 140;
    final h =
        EditTimeline.rulerHeight +
        EditTimeline.videoHeight +
        (EditTimeline.gap + EditTimeline.trackHeight) *
            (2 + (widget.voice ? 1 : 0) + widget.lanes.length) +
        12;
    final rows = <Widget>[
      SizedBox(
        height: EditTimeline.rulerHeight,
        child: CustomPaint(
          size: Size(fullW, EditTimeline.rulerHeight),
          painter: _RulerPainter(total: _len, pps: _pps, left: _pad),
        ),
      ),
      _videoRow(contentW),
      const SizedBox(height: EditTimeline.gap),
      _audioRow(contentW),
      if (widget.voice) ...[
        const SizedBox(height: EditTimeline.gap),
        _voiceRow(contentW),
      ],
      for (var i = 0; i < widget.lanes.length; i++) ...[
        const SizedBox(height: EditTimeline.gap),
        _laneRow(i, contentW),
      ],
      const SizedBox(height: EditTimeline.gap),
      _addRow(
        const ValueKey('addTextTrack'),
        Icons.add_rounded,
        'Add text',
        widget.onAddText,
        contentW,
      ),
      const SizedBox(height: 12),
    ];
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        // the tracks slide; only this transform changes while the clip plays
        Positioned.fill(
          child: ClipRect(
            child: SingleChildScrollView(
              key: const ValueKey('laneList'),
              child: SizedBox(
                width: width,
                height: h,
                // the box is as wide as the screen (so every touch on it counts); the
                // tracks inside are as long as the clip and slide under the playhead
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: fullW,
                  maxWidth: fullW,
                  minHeight: h,
                  maxHeight: h,
                  child: ValueListenableBuilder<double>(
                    valueListenable: widget.position,
                    builder: (context, pos, child) => Transform.translate(
                      offset: Offset(center - _x(pos), 0),
                      child: child,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: rows,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // the original sound switch stays at the left, like in the picture
        Positioned(
          left: 0,
          top: EditTimeline.rulerHeight,
          height: EditTimeline.videoHeight,
          child: IgnorePointer(
            ignoring: widget.onMuteTap == null,
            child: InkWell(
              key: const ValueKey('timelineMute'),
              onTap: widget.onMuteTap,
              child: SizedBox(
                width: 52,
                child: Icon(
                  widget.muted
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                  color: widget.muted ? Colors.redAccent : Colors.white60,
                  size: 22,
                ),
              ),
            ),
          ),
        ),
        // the playhead
        Positioned(
          left: center - 1,
          top: 6,
          bottom: 0,
          child: IgnorePointer(
            child: Container(
              key: const ValueKey('playhead'),
              width: 2,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(1),
                boxShadow: const [
                  BoxShadow(color: Colors.black54, blurRadius: 4),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Where [sec] is on the tracks.
  double _x(double sec) => _pad + sec * _pps;

  /// How wide [sec] seconds are.
  double _w(double sec) => sec * _pps;

  /// Drags a handle: [dx] in points to seconds.
  double _dt(double dx) => dx / _pps;

  Widget _videoRow(double contentW) {
    final s = widget.start, e = widget.end;
    final sel = widget.videoSelected;
    final n = widget.frames.length;
    return SizedBox(
      key: const ValueKey('videoTrack'),
      width: _pad * 2 + contentW + 140,
      height: EditTimeline.videoHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // the frames over the whole clip
          Positioned(
            left: _x(0),
            top: 0,
            width: contentW,
            height: EditTimeline.videoHeight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onVideoTap,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < math.max(n, 1); i++)
                      Expanded(
                        child: n == 0 || widget.frames[i] == null
                            ? const ColoredBox(color: Color(0xFF26262B))
                            : Image.memory(
                                widget.frames[i]!,
                                fit: BoxFit.cover,
                                height: EditTimeline.videoHeight,
                                gaplessPlayback: true,
                              ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // what is cut away is dimmed
          if (s > 0)
            Positioned(
              left: _x(0),
              width: _w(s),
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(10),
                    ),
                  ),
                ),
              ),
            ),
          if (e < _len)
            Positioned(
              left: _x(e),
              width: _w(_len - e),
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: const BorderRadius.horizontal(
                      right: Radius.circular(10),
                    ),
                  ),
                ),
              ),
            ),
          // frame around the kept part, white when selected
          Positioned(
            left: _x(s),
            width: _w(e - s),
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: sel ? Colors.white : Colors.white24,
                    width: sel ? 2.5 : 1,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          if (sel) ...[
            _handle(
              const ValueKey('trimStart'),
              _x(s) - 14,
              EditTimeline.videoHeight,
              (dx) {
                final ns = (s + _dt(dx)).clamp(0.0, e - 1);
                final cap = widget.maxSeconds;
                final ne = cap != null && e - ns > cap ? ns + cap : e;
                widget.onRange?.call(ns, ne, true);
              },
            ),
            _handle(
              const ValueKey('trimEnd'),
              _x(e) - 14,
              EditTimeline.videoHeight,
              (dx) {
                final ne = (e + _dt(dx)).clamp(s + 1, _len);
                final cap = widget.maxSeconds;
                final ns = cap != null && ne - s > cap ? ne - cap : s;
                widget.onRange?.call(ns, ne, false);
              },
            ),
          ],
          // add another clip (the button at the end of the clip)
          if (widget.onAddClip != null)
            Positioned(
              left: _x(_len) + 12,
              top: (EditTimeline.videoHeight - 44) / 2,
              child: _roundButton(
                const ValueKey('addClip'),
                Icons.add_rounded,
                widget.onAddClip!,
              ),
            ),
        ],
      ),
    );
  }

  Widget _roundButton(Key key, IconData icon, VoidCallback onTap) => Material(
    key: key,
    color: Colors.white,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Icon(icon, color: Colors.black, size: 28),
      ),
    ),
  );

  /// A white grip that is dragged sideways; [onDrag] gets the movement in points.
  Widget _handle(
    Key key,
    double left,
    double height,
    ValueChanged<double> onDrag,
  ) => Positioned(
    left: left,
    top: 0,
    height: height,
    width: 28,
    child: GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
      child: Center(
        child: Container(
          width: 14,
          height: math.min(height - 8, 36),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(5),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4)],
          ),
          child: Center(
            child: Container(width: 2, height: 14, color: Colors.black54),
          ),
        ),
      ),
    ),
  );

  /// A block on a track from [from] to [to] seconds.
  Widget _block({
    required Key key,
    required double from,
    required double to,
    required Color color,
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    bool selected = false,
    bool bars = false,
  }) {
    final w = math.max(_w(to - from), 24.0);
    return Positioned(
      left: _x(from),
      width: w,
      top: 0,
      height: EditTimeline.trackHeight,
      child: GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(10),
            border: selected
                ? Border.all(color: Colors.white, width: 2.5)
                : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Stack(
            children: [
              if (bars)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _BarsPainter(seed: label.hashCode),
                  ),
                ),
              Row(
                children: [
                  Icon(icon, size: 16, color: Colors.white),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _track(Key key, double contentW, List<Widget> children) => SizedBox(
    key: key,
    width: _pad * 2 + contentW + 140,
    height: EditTimeline.trackHeight,
    child: Stack(clipBehavior: Clip.none, children: children),
  );

  Widget _audioRow(double contentW) {
    final label = widget.audioLabel;
    if (label == null) {
      return _addRow(
        const ValueKey('addAudioTrack'),
        Icons.add_rounded,
        'Add audio',
        widget.onAddAudio,
        contentW,
      );
    }
    return _track(const ValueKey('audioLane'), contentW, [
      _block(
        key: const ValueKey('audioBlock'),
        from: widget.start,
        to: widget.end,
        color: const Color(0xFF6C4CF1),
        icon: Icons.music_note_rounded,
        label: label,
        onTap: widget.onAudioTap,
        bars: true,
      ),
    ]);
  }

  Widget _voiceRow(double contentW) =>
      _track(const ValueKey('voiceLane'), contentW, [
        _block(
          key: const ValueKey('voiceBlock'),
          from: widget.start,
          to: widget.end,
          color: const Color(0xFFE0446A),
          icon: Icons.mic_rounded,
          label: 'Voiceover',
          onTap: widget.onVoiceTap,
          bars: true,
        ),
      ]);

  Widget _laneRow(int i, double contentW) {
    final l = widget.lanes[i];
    final from = l.from.clamp(0.0, _len);
    final to = (l.to < 0 ? _len : l.to).clamp(from + 0.5, _len);
    return _track(ValueKey('textLane$i'), contentW, [
      _block(
        key: ValueKey('textBlock$i'),
        from: from,
        to: to,
        color: const Color(0xFF2F8F83),
        icon: l.icon,
        label: l.label,
        selected: l.selected,
        onTap: () => widget.onLaneTap?.call(i),
      ),
      if (l.selected) ...[
        _handle(
          ValueKey('laneStart$i'),
          _x(from) - 14,
          EditTimeline.trackHeight,
          (dx) {
            final nf = (from + _dt(dx)).clamp(0.0, to - 0.5);
            widget.onLaneRange?.call(i, nf, to >= _len - 0.01 ? -1 : to);
          },
        ),
        _handle(ValueKey('laneEnd$i'), _x(to) - 14, EditTimeline.trackHeight, (
          dx,
        ) {
          final nt = (to + _dt(dx)).clamp(from + 0.5, _len);
          widget.onLaneRange?.call(i, from, nt >= _len - 0.01 ? -1 : nt);
        }),
      ],
    ]);
  }

  /// "+ Add audio" / "+ Add text": a dark track that starts at the beginning of the clip.
  Widget _addRow(
    Key key,
    IconData icon,
    String label,
    VoidCallback? onTap,
    double contentW,
  ) => _track(key, contentW, [
    Positioned(
      left: _x(0),
      width: math.max(contentW, 160),
      top: 0,
      height: EditTimeline.trackHeight,
      child: Material(
        color: const Color(0xFF232327),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Icon(icon, color: Colors.white70, size: 24),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  ]);
}

/// Time marks: a dot every second (or less often when zoomed out), a label every few.
class _RulerPainter extends CustomPainter {
  _RulerPainter({required this.total, required this.pps, this.left = 0});

  final double total;
  final double pps;
  final double left;

  @override
  void paint(Canvas canvas, Size size) {
    final dot = Paint()..color = Colors.white38;
    // a label at least ~70 points apart
    const steps = [1, 2, 5, 10, 15, 30, 60];
    final label = steps.firstWhere((s) => s * pps >= 70, orElse: () => 60);
    final tick = label >= 5 ? label / 5 : 1.0;
    final y = size.height / 2;
    for (var t = 0.0; t <= total + 0.001; t += tick) {
      final x = left + t * pps;
      final isLabel = (t / label - (t / label).round()).abs() < 0.001;
      if (isLabel && t > 0) {
        final tp = TextPainter(
          text: TextSpan(
            text: _fmt(t),
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x - tp.width / 2, y - tp.height / 2));
      } else {
        canvas.drawCircle(Offset(x, y), 2, dot);
      }
    }
  }

  static String _fmt(double t) {
    final s = t.round();
    return s < 60
        ? '${s}s'
        : '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.total != total || old.pps != pps || old.left != left;
}

/// Soft sound bars behind an audio block.
class _BarsPainter extends CustomPainter {
  _BarsPainter({required this.seed});

  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.white.withValues(alpha: 0.18);
    final r = math.Random(seed);
    for (var x = 2.0; x < size.width; x += 5) {
      final h = size.height * (0.2 + r.nextDouble() * 0.6);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, (size.height - h) / 2, 2.5, h),
          const Radius.circular(2),
        ),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.seed != seed;
}
