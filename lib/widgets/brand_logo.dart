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

/// The font family of the wordmark (registered in pubspec.yaml).
const String kWordmarkFont = 'Wordmark';

/// "InstantGram" as text in the brand font (Login, Create account and the feed header).
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
      // Pacifico (assets/fonts, SIL Open Font License); falls back to the normal font
      fontFamily: kWordmarkFont,
      fontSize: size * 1.12,
      fontWeight: FontWeight.w400,
      height: 1.25,
    ),
  );
}
