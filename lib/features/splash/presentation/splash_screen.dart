import 'package:flutter/material.dart';

import '../../../shared/widgets/glow_background.dart';
import '../../../shared/widgets/ig_logo.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: GlowBackground(child: Center(child: IgLogo(size: 44))),
    );
  }
}
