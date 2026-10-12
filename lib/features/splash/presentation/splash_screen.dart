import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_theme.dart';

/// Temporary splash screen — will be replaced with your UI designs.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ShaderMask(
              shaderCallback: (bounds) =>
                  AppTheme.brandGradient.createShader(bounds),
              child: const Icon(
                Icons.camera_alt_outlined,
                size: 96,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              AppConstants.appName,
              style: textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text('Setup complete ✅', style: textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
