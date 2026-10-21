import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// v0.0.1 tablets: how wide the app column may be on [screen].
/// Returns null when the app should simply fill the screen (phones held
/// upright, small tablets held upright).
double? tabletFrameWidth(Size screen) {
  final w = screen.width, h = screen.height;
  if (w < 600) return null; // phone upright
  double target;
  if (w > h * 0.85) {
    // landscape / wide: a tall column, like a phone in the middle
    target = (h * 0.8).clamp(420.0, 720.0);
  } else {
    // big tablet held upright: limit the stretch
    target = 820;
  }
  if (target >= w - 24) return null; // tiny margins look broken
  return target;
}

/// Centers the whole app in a column on wide screens (tablets, landscape,
/// foldables). Pages, sheets, dialogs and call screens all live inside the
/// column, and they see the column size in [MediaQuery].
class TabletFrame extends StatelessWidget {
  const TabletFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final fw = tabletFrameWidth(mq.size);
    if (fw == null) return child;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: DecoratedBox(
          key: const ValueKey('tablet-frame'),
          position: DecorationPosition.foreground,
          decoration: const BoxDecoration(
            border: Border.symmetric(
              vertical: BorderSide(color: AppColors.border, width: 0.5),
            ),
          ),
          child: SizedBox(
            width: fw,
            height: mq.size.height,
            child: MediaQuery(
              data: mq.copyWith(
                size: Size(fw, mq.size.height),
                // the column sits away from the side cut-outs/bars
                padding: mq.padding.copyWith(left: 0, right: 0),
                viewPadding: mq.viewPadding.copyWith(left: 0, right: 0),
                systemGestureInsets: mq.systemGestureInsets.copyWith(
                  left: 0,
                  right: 0,
                ),
              ),
              child: ClipRect(child: child),
            ),
          ),
        ),
      ),
    );
  }
}
