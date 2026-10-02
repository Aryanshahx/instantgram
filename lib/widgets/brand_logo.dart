import 'package:flutter/material.dart';

import '../core/theme.dart';

class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (rect) => AppTheme.instaGradient.createShader(rect),
      child: Text(
        'Instantgram',
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w800,
          fontStyle: FontStyle.italic,
          letterSpacing: -0.5,
          color: Colors.white,
        ),
      ),
    );
  }
}
