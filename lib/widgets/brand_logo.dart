import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Bolt badge + lowercase wordmark.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = 28, this.showText = true});
  final double size;
  final bool showText;

  @override
  Widget build(BuildContext context) {
    final badge = size * 1.15;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: badge,
          height: badge,
          decoration: BoxDecoration(
            gradient: AppTheme.voltGradient,
            borderRadius: BorderRadius.circular(badge * 0.34),
          ),
          child: Icon(
            Icons.bolt_rounded,
            color: AppTheme.ink,
            size: badge * 0.72,
          ),
        ),
        if (showText) ...[
          SizedBox(width: size * 0.3),
          Text(
            'instantgram',
            style: TextStyle(
              fontSize: size * 0.82,
              fontWeight: FontWeight.w900,
              letterSpacing: -1,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ],
    );
  }
}
