import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Dark background with soft purple / green / olive glows (Login screen).
class GlowBackground extends StatelessWidget {
  const GlowBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: ColoredBox(color: AppColors.background)),
        _glow(const Alignment(0.4, -0.95), AppColors.glowPurple, 1.1),
        _glow(const Alignment(-1.1, 0.1), AppColors.glowGreen, 1.0),
        _glow(const Alignment(0.2, 1.05), AppColors.glowOlive, 0.9),
        Positioned.fill(child: child),
      ],
    );
  }

  Widget _glow(Alignment center, Color color, double radius) {
    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: center,
            radius: radius,
            colors: [
              color.withValues(alpha: 0.85),
              color.withValues(alpha: 0.0),
            ],
          ),
        ),
      ),
    );
  }
}
