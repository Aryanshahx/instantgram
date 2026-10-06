import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Gives a short vibration whenever a finger stays pressed on the screen for half a second
/// (a press-and-hold anywhere in the app). It only listens: taps, scrolls and the real
/// long-press actions work exactly as before. The hold is dropped when the finger moves
/// (a scroll or a drag), when it lifts, or when a second finger arrives (a pinch).
class HoldHaptics extends StatefulWidget {
  const HoldHaptics({super.key, required this.child, this.onHold});

  final Widget child;

  /// Test seam; the default is a medium vibration.
  final VoidCallback? onHold;

  @override
  State<HoldHaptics> createState() => _HoldHapticsState();
}

class _HoldHapticsState extends State<HoldHaptics> {
  final Map<int, Offset> _start = {};
  Timer? _timer;

  void _cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void _down(PointerDownEvent e) {
    _start[e.pointer] = e.position;
    if (_start.length > 1) {
      _cancel();
      return;
    }
    _timer = Timer(kLongPressTimeout, () {
      _timer = null;
      if (widget.onHold != null) {
        widget.onHold!();
      } else {
        HapticFeedback.mediumImpact();
      }
    });
  }

  void _move(PointerMoveEvent e) {
    final from = _start[e.pointer];
    if (from != null && (e.position - from).distance > kTouchSlop) _cancel();
  }

  void _end(PointerEvent e) {
    _start.remove(e.pointer);
    _cancel();
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _end,
      onPointerCancel: _end,
      child: widget.child,
    );
  }
}
