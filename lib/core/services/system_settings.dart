import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Opens Android settings pages (v0.11, MainActivity.kt "instantgram/system").
abstract final class SystemSettings {
  static const _ch = MethodChannel('instantgram/system');

  /// App info page (Oppo / Realme / OnePlus / Vivo: battery, auto launch).
  static Future<void> app() => _call('openAppSettings');

  /// This app's notification settings.
  static Future<void> notifications() => _call('openNotificationSettings');

  /// Phone maker in lower case ("oppo", "realme", "oneplus", "vivo" ...).
  static Future<String> maker() async {
    try {
      return (await _ch.invokeMethod<String>('maker') ?? '').toLowerCase();
    } catch (_) {
      return '';
    }
  }

  /// Removes the "username: message" notification of a chat.
  static Future<void> clearChatNotification(String chatId) async {
    try {
      await _ch.invokeMethod<void>('cancelNotification', {'tag': 'chat_$chatId'});
    } catch (_) {}
  }

  static Future<void> _call(String m) async {
    try {
      await _ch.invokeMethod<void>(m);
    } catch (e) {
      debugPrint('settings $m: $e');
    }
  }
}
