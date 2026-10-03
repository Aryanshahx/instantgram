import 'package:flutter/material.dart';

/// Keeps content readable on tablets: centred column with a max width.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth = 680});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// Number of masonry columns for a given available width.
int gridColumnsFor(double width) {
  if (width >= 760) return 4;
  if (width >= 500) return 3;
  return 2;
}
