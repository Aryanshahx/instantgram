import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps uploads going when you leave the app (v0.8): while something is
/// uploading, Android shows a small "Posting… 45%" notification. This
/// "foreground service" stops Android from pausing the app.
class BackgroundUpload {
  BackgroundUpload._();

  /// Tests switch this off.
  static bool disabled = false;

  static bool _inited = false;
  static bool _running = false;
  static bool _askedPermission = false;
  static DateTime _lastText = DateTime.fromMillisecondsSinceEpoch(0);

  static bool get _android => !kIsWeb && Platform.isAndroid && !disabled;

  static void _init() {
    if (_inited) return;
    _inited = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'uploads',
        channelName: 'Uploads',
        channelDescription: 'Shows while your posts are uploading',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
        allowAutoRestart: false,
        stopWithTask: true,
      ),
    );
  }

  /// Shows the notification (starts the service).
  static Future<void> start(String text) async {
    if (!_android) return;
    try {
      _init();
      if (!_askedPermission) {
        _askedPermission = true;
        final p = await FlutterForegroundTask.checkNotificationPermission();
        if (p != NotificationPermission.granted) {
          await FlutterForegroundTask.requestNotificationPermission();
        }
      }
      if (_running || await FlutterForegroundTask.isRunningService) {
        _running = true;
        await update(text, force: true);
        return;
      }
      await FlutterForegroundTask.startService(
        serviceId: 708,
        serviceTypes: const [ForegroundServiceTypes.dataSync],
        notificationTitle: 'InstantGram',
        notificationText: text,
        callback: uploadServiceCallback,
      );
      _running = true;
    } catch (e) {
      debugPrint('background upload: $e');
    }
  }

  /// New notification text (at most every 1.5 s).
  static Future<void> update(String text, {bool force = false}) async {
    if (!_android || !_running) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastText).inMilliseconds < 1500) return;
    _lastText = now;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'InstantGram',
        notificationText: text,
      );
    } catch (_) {}
  }

  /// Removes the notification.
  static Future<void> stop() async {
    if (!_android || !_running) return;
    _running = false;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }
}

/// Runs in the service. The upload itself runs in the app; the service
/// only keeps the app awake, so this does nothing.
@pragma('vm:entry-point')
void uploadServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAwake());
}

class _KeepAwake extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
