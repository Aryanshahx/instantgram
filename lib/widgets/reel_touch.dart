import 'package:flutter/material.dart';

/// App-wide sound settings for clips.
class ReelAudio {
  /// Sound switch (the speaker button).
  static final ValueNotifier<bool> muted = ValueNotifier<bool>(false);

  /// Loudness from 0 to 1, set by holding a finger on a clip and sliding up or down.
  static final ValueNotifier<double> volume = ValueNotifier<double>(1);

  /// What the players should use right now.
  static double get effective => muted.value ? 0 : volume.value;
}

/// Touch handling shared by every clip on the Clips screen:
///  * tap: [onTap] (pause / resume)
///  * double tap: [onDoubleTap] with a heart popping up under the finger
///  * hold: [onSpeed] (true = 2x speed) while the finger stays still
///  * hold and slide up / down: volume (a bar shows the level). Sliding replaces the 2x speed.
class ReelTouch extends StatefulWidget {
  const ReelTouch({
    super.key,
    required this.child,
    required this.onTap,
    this.onDoubleTap,
    this.onSpeed,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;
  final ValueChanged<bool>? onSpeed;

  @override
  State<ReelTouch> createState() => _ReelTouchState();
}

class _ReelTouchState extends State<ReelTouch> {
  /// How far the finger has to slide before it counts as "volume" (not "2x").
  static const double _slop = 22;

  Offset _tapAt = Offset.zero;
  Offset? _burstAt;
  int _burstId = 0;
  bool _fast = false;
  bool _sliding = false;
  bool _hud = false;
  double _startVolume = 1;
  int _hudId = 0;

  void _doubleTap() {
    final id = ++_burstId;
    setState(() => _burstAt = _tapAt);
    widget.onDoubleTap?.call();
    Future<void>.delayed(const Duration(milliseconds: 800), () {
      if (mounted && _burstId == id) setState(() => _burstAt = null);
    });
  }

  void _setFast(bool v) {
    if (_fast == v) return;
    setState(() => _fast = v);
    widget.onSpeed?.call(v);
  }

  void _holdStart() {
    _sliding = false;
    _startVolume = ReelAudio.volume.value;
    _setFast(true);
  }

  void _holdMove(LongPressMoveUpdateDetails d, double height) {
    final dy = d.offsetFromOrigin.dy;
    if (!_sliding && dy.abs() > _slop) {
      _sliding = true;
      _setFast(false);
      setState(() => _hud = true);
    }
    if (_sliding) {
      // sliding up raises the volume; the full height of the screen is about 100%
      final delta = -(dy - (dy.isNegative ? -_slop : _slop)) / (height * 0.55);
      final v = (_startVolume + delta).clamp(0.0, 1.0);
      ReelAudio.volume.value = v;
      if (v > 0 && ReelAudio.muted.value) ReelAudio.muted.value = false;
    }
  }

  void _holdEnd() {
    _setFast(false);
    if (_sliding) {
      _sliding = false;
      final id = ++_hudId;
      Future<void>.delayed(const Duration(milliseconds: 700), () {
        if (mounted && _hudId == id) setState(() => _hud = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onDoubleTapDown: (d) => _tapAt = d.localPosition,
      onDoubleTap: widget.onDoubleTap == null ? null : _doubleTap,
      onLongPressStart: (_) => _holdStart(),
      onLongPressMoveUpdate: (d) => _holdMove(d, height),
      onLongPressEnd: (_) => _holdEnd(),
      onLongPressCancel: _holdEnd,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
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
              child: const IgnorePointer(child: Center(child: _SpeedChip())),
            ),
          if (_hud)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Align(
                  alignment: const Alignment(-0.82, 0),
                  child: ValueListenableBuilder<double>(
                    valueListenable: ReelAudio.volume,
                    builder: (_, v, _) => _VolumeBar(value: v),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SpeedChip extends StatelessWidget {
  const _SpeedChip();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
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
        Icon(Icons.fast_forward_rounded, color: Colors.white, size: 20),
      ],
    ),
  );
}

class _VolumeBar extends StatelessWidget {
  const _VolumeBar({required this.value});
  final double value;

  @override
  Widget build(BuildContext context) {
    final icon = value <= 0
        ? Icons.volume_off_rounded
        : value < 0.5
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;
    return Container(
      key: const ValueKey('volumeBar'),
      width: 46,
      height: 190,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          Icon(icon, color: Colors.white, size: 22),
          const SizedBox(height: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 7,
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    const ColoredBox(color: Colors.white24),
                    FractionallySizedBox(
                      heightFactor: value.clamp(0.0, 1.0),
                      child: const ColoredBox(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${(value * 100).round()}',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
