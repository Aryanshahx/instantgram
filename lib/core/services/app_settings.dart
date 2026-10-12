import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Small on-device settings (kept after the app closes).
class AppSettings {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  static const _kAutoScroll = 'clips_auto_scroll';

  /// Clips: go to the next clip automatically when one ends.
  final ValueNotifier<bool> clipsAutoScroll = ValueNotifier(false);

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      clipsAutoScroll.value = p.getBool(_kAutoScroll) ?? false;
    } catch (_) {
      // settings are optional — keep defaults
    }
  }

  Future<void> setClipsAutoScroll(bool on) async {
    clipsAutoScroll.value = on;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kAutoScroll, on);
    } catch (_) {}
  }
}
