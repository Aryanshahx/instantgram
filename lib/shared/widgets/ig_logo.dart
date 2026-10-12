import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';

/// The "InstantGram" script logo.
class IgLogo extends StatelessWidget {
  const IgLogo({super.key, this.size = 34});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Text(
      AppConstants.appName,
      style: TextStyle(
        fontFamily: AppTheme.logoFontFamily,
        fontSize: size,
        color: AppColors.textPrimary,
        height: 1.2,
      ),
    );
  }
}
