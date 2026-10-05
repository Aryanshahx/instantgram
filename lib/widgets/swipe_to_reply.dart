import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';

/// Drag a message to the right and let go to reply to it.
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({
    super.key,
    required this.child,
    required this.onReply,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onReply;
  final bool enabled;

  /// How far (dp) the message must be dragged.
  static const double trigger = 56;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  double _dx = 0;
  bool _armed = false;
  late final AnimationController _back = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..addListener(() => setState(() => _dx = _from * (1 - _back.value)));
  double _from = 0;

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    if (!widget.enabled) return;
    final next = (_dx + d.delta.dx).clamp(0.0, 84.0);
    if (!_armed && next >= SwipeToReply.trigger) {
      _armed = true;
      HapticFeedback.selectionClick();
    } else if (_armed && next < SwipeToReply.trigger) {
      _armed = false;
    }
    setState(() => _dx = next);
  }

  void _end(DragEndDetails _) {
    if (_armed) widget.onReply();
    _armed = false;
    _from = _dx;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final p = (_dx / SwipeToReply.trigger).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: () {
        _armed = false;
        _from = _dx;
        _back.forward(from: 0);
      },
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Positioned(
            left: 6,
            child: Opacity(
              opacity: p,
              child: Transform.scale(
                scale: 0.5 + 0.5 * p,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: context.cardHigh,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.reply_rounded, size: 19),
                ),
              ),
            ),
          ),
          Transform.translate(offset: Offset(_dx, 0), child: widget.child),
        ],
      ),
    );
  }
}
