import 'package:flutter/material.dart';

import '../services/app_prefs.dart';

/// The accessibility choices (Settings > Accessibility). The app reads them in `app.dart`.
class A11y extends ChangeNotifier {
  A11y._();
  static final A11y instance = A11y._();

  double _scale = 1;
  bool _bold = false;
  bool _reduce = false;
  ThemeMode _theme = ThemeMode.system;

  void load() {
    _scale = AppPrefs.instance.textScale;
    _bold = AppPrefs.instance.boldText;
    _reduce = AppPrefs.instance.reduceMotion;
    _theme = switch (AppPrefs.instance.themeMode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    notifyListeners();
  }

  ThemeMode get themeMode => _theme;
  double get textScale => _scale;
  bool get boldText => _bold;
  bool get reduceMotion => _reduce;

  set themeMode(ThemeMode v) {
    _theme = v;
    AppPrefs.instance.themeMode = switch (v) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    notifyListeners();
  }

  set textScale(double v) {
    _scale = v.clamp(0.8, 1.6);
    AppPrefs.instance.textScale = _scale;
    notifyListeners();
  }

  set boldText(bool v) {
    _bold = v;
    AppPrefs.instance.boldText = v;
    notifyListeners();
  }

  set reduceMotion(bool v) {
    _reduce = v;
    AppPrefs.instance.reduceMotion = v;
    notifyListeners();
  }
}
