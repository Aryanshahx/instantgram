import 'package:flutter/material.dart';

/// Space reserved at the bottom of scrollable screens for the floating nav bar.
const double kNavSpace = 104;

/// "Volt" design system: ink-black / warm-cream surfaces, electric lime accent,
/// big rounded cards, squircle avatars and a floating pill navigation.
class AppTheme {
  static const Color volt = Color(0xFFD2FF3F);
  static const Color mint = Color(0xFF4DF0B4);
  static const Color violet = Color(0xFF7B6CFF);
  static const Color coral = Color(0xFFFF5C6C);
  static const Color ink = Color(0xFF0B0D12);

  static const LinearGradient voltGradient = LinearGradient(
    colors: [volt, mint],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient auroraGradient = LinearGradient(
    colors: [violet, mint, volt],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final isDark = b == Brightness.dark;
    final bg = isDark ? const Color(0xFF0B0D12) : const Color(0xFFF3F2EC);
    final card = isDark ? const Color(0xFF14171F) : Colors.white;
    final cardHigh = isDark ? const Color(0xFF1D212B) : const Color(0xFFE9E7DE);
    final outline = isDark ? const Color(0xFF2A2F3A) : const Color(0xFFDAD7CC);
    final text = isDark ? const Color(0xFFF2F4F8) : const Color(0xFF12141A);

    final scheme = ColorScheme.fromSeed(seedColor: volt, brightness: b).copyWith(
      primary: volt,
      onPrimary: ink,
      secondary: violet,
      onSecondary: Colors.white,
      error: coral,
      surface: card,
      onSurface: text,
      outline: outline,
    );

    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: c, width: w),
        );

    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      dividerColor: outline,
      dividerTheme: DividerThemeData(color: outline, thickness: 0.6, space: 0.6),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: text,
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        hintStyle: TextStyle(color: text.withValues(alpha: 0.45)),
        border: border(outline),
        enabledBorder: border(outline),
        focusedBorder: border(isDark ? volt : ink, 1.6),
        errorBorder: border(coral),
        focusedErrorBorder: border(coral, 1.6),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: volt,
          foregroundColor: ink,
          disabledBackgroundColor: volt.withValues(alpha: 0.35),
          disabledForegroundColor: ink.withValues(alpha: 0.5),
          minimumSize: const Size.fromHeight(54),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          textStyle: const TextStyle(
              fontWeight: FontWeight.w800, fontSize: 16, letterSpacing: -0.2),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          minimumSize: const Size.fromHeight(48),
          side: BorderSide(color: outline),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: isDark ? volt : ink,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      progressIndicatorTheme:
          ProgressIndicatorThemeData(color: isDark ? volt : ink),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? cardHigh : ink,
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: card,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      ),
    );
  }
}

extension ThemeContext on BuildContext {
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
  Color get bg => Theme.of(this).scaffoldBackgroundColor;
  Color get card => isDark ? const Color(0xFF14171F) : Colors.white;
  Color get cardHigh =>
      isDark ? const Color(0xFF1D212B) : const Color(0xFFE9E7DE);
  Color get softFill => cardHigh;
  Color get muted => Theme.of(this).colorScheme.onSurface.withValues(alpha: 0.58);
  Color get hairline =>
      isDark ? const Color(0xFF2A2F3A) : const Color(0xFFDAD7CC);

  /// Accent usable as TEXT/ICON colour on the current background
  /// (lime on dark, ink on cream).
  Color get accentInk => isDark ? AppTheme.volt : AppTheme.ink;
}
