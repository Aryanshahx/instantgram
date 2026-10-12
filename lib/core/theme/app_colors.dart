import 'package:flutter/material.dart';

/// InstantGram colour palette (picked from the UI designs).
class AppColors {
  AppColors._();

  static const Color background = Color(0xFF0C0D12);
  static const Color surface = Color(0xFF141720);
  static const Color surfaceHigh = Color(0xFF1D2029);
  static const Color navBar = Color(0xFF12151C);
  static const Color border = Color(0xFF262B35);

  static const Color lime = Color(0xFFD2FF40);
  static const Color mint = Color(0xFF62F0A4);
  static const Color like = Color(0xFFFF4D5E);

  static const Color textPrimary = Color(0xFFF3F4F8);
  static const Color textSecondary = Color(0xFF8A8D96);
  static const Color textHint = Color(0xFF6E717A);

  // Login glow colours
  static const Color glowPurple = Color(0xFF494194);
  static const Color glowGreen = Color(0xFF205044);
  static const Color glowOlive = Color(0xFF42501F);

  static const LinearGradient fabGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [lime, mint],
  );
}
