import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Soft glowing blobs behind the auth screens.
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({super.key, required this.child});
  final Widget child;

  Widget _blob(Color c, double size, double alpha) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        colors: [
          c.withValues(alpha: alpha),
          c.withValues(alpha: 0),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final dark = context.isDark;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: context.bg),
        Positioned(
          top: -120,
          right: -100,
          child: _blob(AppTheme.violet, 420, dark ? 0.55 : 0.35),
        ),
        Positioned(
          top: 220,
          left: -160,
          child: _blob(AppTheme.mint, 420, dark ? 0.35 : 0.35),
        ),
        Positioned(
          bottom: -160,
          right: -80,
          child: _blob(AppTheme.volt, 420, dark ? 0.28 : 0.55),
        ),
        child,
      ],
    );
  }
}
