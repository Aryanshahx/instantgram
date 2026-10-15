import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// v0.15: change the launcher icon (MainActivity.kt activity aliases).
abstract final class AppIcons {
  static const _ch = MethodChannel('instantgram/system');

  /// id -> name. Ids must match MainActivity.kt + AndroidManifest.xml.
  static const Map<String, String> all = {
    'default': 'Classic',
    'night': 'Night',
    'sunset': 'Sunset',
    'ocean': 'Ocean',
    'berry': 'Berry',
    'mono': 'Light',
  };

  static String normalize(Object? id) =>
      id is String && all.containsKey(id) ? id : 'default';

  static String asset(String id) =>
      'assets/images/app_icon_${normalize(id)}.png';

  /// Tests.
  @visibleForTesting
  static Future<String> Function()? debugGet;
  @visibleForTesting
  static Future<String> Function(String id)? debugSet;

  static Future<String> current() async {
    if (debugGet != null) return debugGet!();
    try {
      return normalize(await _ch.invokeMethod<String>('getAppIcon'));
    } catch (_) {
      return 'default';
    }
  }

  /// Returns the icon now in use.
  static Future<String> set(String id) async {
    final want = normalize(id);
    if (debugSet != null) return debugSet!(want);
    try {
      return normalize(
        await _ch.invokeMethod<String>('setAppIcon', {'icon': want}),
      );
    } catch (e) {
      debugPrint('app icon: $e');
      return current();
    }
  }
}
