import 'package:flutter/material.dart';

/// The app logo (the picture the app icon is made from).
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 96});
  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/logo/instantgram_logo.png',
    width: size,
    height: size,
    filterQuality: FilterQuality.medium,
    errorBuilder: (_, _, _) => SizedBox(width: size, height: size),
  );
}

/// "InstantGram" as plain bold text (same look as the header of the feed).
class BrandWordmark extends StatelessWidget {
  const BrandWordmark({
    super.key,
    this.size = 26,
    this.align = TextAlign.start,
  });
  final double size;
  final TextAlign align;

  @override
  Widget build(BuildContext context) => Text(
    'InstantGram',
    textAlign: align,
    style: TextStyle(
      fontSize: size,
      fontWeight: FontWeight.w900,
      letterSpacing: -size * 0.046,
    ),
  );
}
