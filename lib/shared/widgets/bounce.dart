import 'package:flutter/material.dart';

/// Springy "pop" for action buttons (like, comment, repost, share, save).
/// Bounces when tapped ([play] from a parent) and whenever [trigger]
/// changes (e.g. liked -> the heart pops).
class Bounce extends StatefulWidget {
  const Bounce({super.key, required this.child, this.trigger, this.big = false});

  final Widget child;

  /// Bounce when this value changes.
  final Object? trigger;

  /// Bigger pop (turning a like on).
  final bool big;

  @override
  State<Bounce> createState() => BounceState();
}

class BounceState extends State<Bounce> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late Animation<double> _scale = _make(widget.big);

  static Animation<double> _seq(AnimationController c, double top) =>
      TweenSequence<double>([
        TweenSequenceItem(
          tween: Tween(begin: 1.0, end: top)
              .chain(CurveTween(curve: Curves.easeOut)),
          weight: 35,
        ),
        TweenSequenceItem(
          tween: Tween(begin: top, end: 0.9)
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: 30,
        ),
        TweenSequenceItem(
          tween: Tween(begin: 0.9, end: 1.0)
              .chain(CurveTween(curve: Curves.easeOut)),
          weight: 35,
        ),
      ]).animate(c);

  Animation<double> _make(bool big) => _seq(_c, big ? 1.38 : 1.22);

  /// Starts the bounce.
  void play({bool big = false}) {
    if (!mounted) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    _scale = _make(big || widget.big);
    _c.forward(from: 0);
  }

  @override
  void didUpdateWidget(covariant Bounce oldWidget) {
    super.didUpdateWidget(oldWidget);
    // (a tap just started the pop -> don't restart it)
    if (oldWidget.trigger != widget.trigger && !(_c.isAnimating && _c.value < 0.4)) {
      play();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, child) =>
        Transform.scale(scale: _c.isAnimating ? _scale.value : 1, child: child),
    child: widget.child,
  );
}
