import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/system_volume.dart';
import 'reel_actions.dart' show kReelShadow;

/// App-wide sound settings for clips.
///
/// The level is the phone's real media volume (see [SystemVolume]), so it does not depend on
/// where the volume buttons were left: sliding to 100% is as loud as the phone can be. The
/// players themselves always run at full volume (their own mix is set per clip).
class ReelAudio {
  /// Sound switch (the speaker button).
  static final ValueNotifier<bool> muted = ValueNotifier<bool>(false);

  /// Phone volume from 0 to 1, set by holding a finger on a clip and sliding up or down.
  static final ValueNotifier<double> volume = ValueNotifier<double>(1);

  /// What the players should use right now (the phone's volume does the rest).
  static double get effective => muted.value ? 0 : 1;

  /// Sets the phone's media volume.
  static void setLevel(double v) {
    volume.value = v.clamp(0.0, 1.0);
    SystemVolume.instance.set(volume.value);
  }

  static bool _attached = false;

  /// Starts following the phone's volume (also when the buttons are used).
  static void attachSystem() {
    if (_attached) return;
    _attached = true;
    SystemVolume.instance.level.addListener(() {
      final v = SystemVolume.instance.level.value;
      if (v != null && (v - volume.value).abs() > 0.001) volume.value = v;
    });
    SystemVolume.instance.start();
  }
}

/// Touch handling shared by every clip on the Clips screen:
///  * tap: [onTap] (pause / resume)
///  * double tap: [onDoubleTap] with a heart popping up under the finger
///  * hold: [onSpeed] (true = 2x speed) while the finger stays still
///  * hold and slide up / down: the phone's real media volume (the level shows as a percentage). Sliding replaces the 2x speed.
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
  @override
  void initState() {
    super.initState();
    ReelAudio.attachSystem();
  }

  /// How far the finger has to slide before it counts as "volume" (not "2x").
  static const double _slop = 14;

  /// How long a finger has to rest before it counts as a "hold". Short on purpose: if the
  /// finger starts sliding before this, the page scrolls instead.
  static const Duration _holdTime = Duration(milliseconds: 220);

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
      final delta = -(dy - (dy.isNegative ? -_slop : _slop)) / (height * 0.4);
      final v = (_startVolume + delta).clamp(0.0, 1.0);
      ReelAudio.setLevel(v);
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
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              TapGestureRecognizer.new,
              (g) => g.onTap = widget.onTap,
            ),
        DoubleTapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
              DoubleTapGestureRecognizer.new,
              (g) {
                g.onDoubleTapDown = (d) => _tapAt = d.localPosition;
                g.onDoubleTap = widget.onDoubleTap == null ? null : _doubleTap;
              },
            ),
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(duration: _holdTime),
              (g) {
                g.onLongPressStart = (_) => _holdStart();
                g.onLongPressMoveUpdate = (d) => _holdMove(d, height);
                g.onLongPressEnd = (_) => _holdEnd();
                g.onLongPressCancel = _holdEnd;
              },
            ),
      },
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
                  alignment: const Alignment(0, -0.1),
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

/// "2x" while holding: plain white text and icon, no background.
class _SpeedChip extends StatelessWidget {
  const _SpeedChip();

  @override
  Widget build(BuildContext context) => const Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        '2x',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: 20,
          shadows: kReelShadow,
        ),
      ),
      SizedBox(width: 4),
      Icon(
        Icons.fast_forward_rounded,
        color: Colors.white,
        size: 26,
        shadows: kReelShadow,
      ),
    ],
  );
}

/// Volume while sliding: just the percentage, big white text, no background.
class _VolumeBar extends StatelessWidget {
  const _VolumeBar({required this.value});
  final double value;

  @override
  Widget build(BuildContext context) {
    return Text(
      '${(value * 100).round()}%',
      key: const ValueKey('volumeBar'),
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w900,
        fontSize: 40,
        letterSpacing: -1,
        shadows: kReelShadow,
      ),
    );
  }
}
