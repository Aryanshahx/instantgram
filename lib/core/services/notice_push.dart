import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

/// v0.0.1: admin notices are shown by the app itself, with the picture.
///
/// Before, Android had to download the picture by itself while the app was
/// closed, and phones with battery savers (Xiaomi, Samsung ...) often
/// blocked that: the text came, the picture didn't. Now a notice with a
/// picture comes as a "data" push, the app downloads the picture (8 s max)
/// and shows a big-picture notification. No picture -> text only.
class NoticePush {
  NoticePush._();

  /// Same channel as the other activity notifications (made in
  /// MainActivity.kt).
  static const String channelId = 'activity';
  static const String channelName = 'Activity';
  static const String payload = 'notice';

  /// Biggest picture we show (the admin page sends ~0.5 MB).
  static const int maxImageBytes = 3 * 1024 * 1024;

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  /// Notification tapped while the app runs (set by PushRouter).
  static void Function()? onTap;

  /// Tests: no plugin.
  @visibleForTesting
  static Future<void> Function(NoticeData n, Uint8List? image)? debugShow;

  static Future<void> _init() async {
    if (_ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_instantgram'),
      ),
      onDidReceiveNotificationResponse: (r) {
        if (r.payload == payload) onTap?.call();
      },
    );
    _ready = true;
  }

  /// The app was opened by tapping a notice.
  static Future<bool> openedFromNotice() async {
    try {
      await _init();
      final d = await _plugin.getNotificationAppLaunchDetails();
      return d?.didNotificationLaunchApp == true &&
          d?.notificationResponse?.payload == payload;
    } catch (e) {
      debugPrint('notice launch: $e');
      return false;
    }
  }

  /// Shows a notice (from a push). Never throws.
  static Future<void> show(
    Map<String, dynamic> data, {
    String? title,
    String? body,
    Future<Uint8List?> Function(String url)? download,
  }) async {
    final n = NoticeData.from(data, title: title, body: body);
    if (n == null) return;
    Uint8List? image;
    if (n.image.isNotEmpty) {
      image = await (download ?? downloadImage)(n.image);
    }
    try {
      final test = debugShow;
      if (test != null) return await test(n, image);
      await _init();
      final pic = image == null ? null : ByteArrayAndroidBitmap(image);
      await _plugin.show(
        id: n.id,
        title: n.title,
        body: n.body,
        payload: payload,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            icon: 'ic_stat_instantgram',
            color: const Color(0xFFC6FF3D),
            importance: Importance.high,
            priority: Priority.high,
            largeIcon: pic,
            styleInformation: pic == null
                ? BigTextStyleInformation(n.body)
                : BigPictureStyleInformation(
                    pic,
                    contentTitle: n.title,
                    summaryText: n.body,
                    hideExpandedLargeIcon: true,
                  ),
          ),
        ),
      );
    } catch (e) {
      debugPrint('notice show: $e');
    }
  }

  /// Downloads the picture (https only, max 8 s, max 3 MB). null = no
  /// picture (the notice still shows with its text).
  static Future<Uint8List?> downloadImage(
    String url, {
    http.Client? client,
  }) async {
    final u = Uri.tryParse(url);
    if (u == null || u.scheme != 'https') return null;
    final c = client ?? http.Client();
    try {
      final r = await c.get(u).timeout(const Duration(seconds: 8));
      final type = r.headers['content-type'] ?? '';
      if (r.statusCode != 200 ||
          r.bodyBytes.isEmpty ||
          r.bodyBytes.length > maxImageBytes ||
          (type.isNotEmpty && !type.startsWith('image/'))) {
        return null;
      }
      return r.bodyBytes;
    } catch (e) {
      debugPrint('notice picture: $e');
      return null;
    } finally {
      if (client == null) c.close();
    }
  }
}

/// One notice from a push.
@immutable
class NoticeData {
  const NoticeData({
    required this.id,
    required this.title,
    required this.body,
    this.image = '',
  });

  final int id;
  final String title;
  final String body;
  final String image;

  /// null = no text (nothing to show).
  static NoticeData? from(
    Map<String, dynamic> d, {
    String? title,
    String? body,
  }) {
    String s(Object? v) => v is String ? v.trim() : '';
    final t = s(title).isNotEmpty ? s(title) : s(d['title']);
    final b = s(body).isNotEmpty ? s(body) : s(d['body']);
    if (b.isEmpty) return null;
    final img = s(d['image']);
    return NoticeData(
      // a different id for every notice (they don't replace each other)
      id: DateTime.now().millisecondsSinceEpoch.remainder(1 << 30),
      title: t.isEmpty ? 'InstantGram' : t,
      body: b,
      image: img.startsWith('https://') ? img : '',
    );
  }
}
