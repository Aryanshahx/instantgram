import 'package:flutter/material.dart';

class AppTheme {
  static const Color brand = Color(0xFFE1306C);
  static const Color blue = Color(0xFF0095F6);

  static const LinearGradient instaGradient = LinearGradient(
    colors: [
      Color(0xFFFEDA75),
      Color(0xFFFA7E1E),
      Color(0xFFD62976),
      Color(0xFF962FBF),
      Color(0xFF4F5BD5),
    ],
    begin: Alignment.bottomLeft,
    end: Alignment.topRight,
  );

  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final isDark = b == Brightness.dark;
    final bg = isDark ? Colors.black : Colors.white;
    final border = isDark ? const Color(0xFF363636) : const Color(0xFFDBDBDB);
    final fill = isDark ? const Color(0xFF121212) : const Color(0xFFFAFAFA);
    final scheme = ColorScheme.fromSeed(seedColor: brand, brightness: b)
        .copyWith(primary: blue, surface: bg);

    OutlineInputBorder outline(Color c) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: c),
        );

    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      dividerColor: border,
      dividerTheme: DividerThemeData(color: border, thickness: 0.5, space: 0.5),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: isDark ? Colors.white : Colors.black,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: fill,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: outline(border),
        enabledBorder: outline(border),
        focusedBorder: outline(isDark ? Colors.white54 : Colors.black45),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: blue,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(46),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(40),
          side: BorderSide(color: border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        height: 56,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      tabBarTheme: TabBarThemeData(
        dividerColor: border,
        indicatorColor: isDark ? Colors.white : Colors.black,
        labelColor: isDark ? Colors.white : Colors.black,
        unselectedLabelColor: Colors.grey,
        labelStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }
}

extension ThemeContext on BuildContext {
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
  Color get muted => Theme.of(this).colorScheme.onSurface.withValues(alpha: 0.6);
  Color get hairline =>
      isDark ? const Color(0xFF363636) : const Color(0xFFDBDBDB);
  Color get softFill =>
      isDark ? const Color(0xFF1C1C1C) : const Color(0xFFEFEFEF);
}
