import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import '../../core/services/calls.dart';
import '../../core/services/chat_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../shared/models/user_profile.dart';
import '../chats/presentation/chat_detail_screen.dart';

/// v0.11: what happens with notifications.
/// - Tap "alice: hi" -> the chat with alice opens.
/// - Tap "Voice call from alice" (muted call) -> the silent call screen.
/// - App open + a message from another chat -> a small banner.
class PushRouter {
  PushRouter._();
  static final PushRouter instance = PushRouter._();

  StreamSubscription<RemoteMessage>? _opened;
  StreamSubscription<RemoteMessage>? _foreground;
  bool _started = false;

  /// Main shell (after login).
  Future<void> start() async {
    if (_started || Calls.disabled) return;
    _started = true;
    try {
      final fm = FirebaseMessaging.instance;
      _opened = FirebaseMessaging.onMessageOpenedApp.listen((m) => route(m.data));
      _foreground = FirebaseMessaging.onMessage.listen(_banner);
      final first = await fm.getInitialMessage();
      if (first != null) {
        // let the home screen build first
        await Future<void>.delayed(const Duration(milliseconds: 600));
        route(first.data);
      }
    } catch (e) {
      debugPrint('push router: $e');
    }
  }

  void stop() {
    _opened?.cancel();
    _foreground?.cancel();
    _opened = null;
    _foreground = null;
    _started = false;
  }

  /// A notification was tapped.
  void route(Map<String, dynamic> d) {
    switch (d['type']) {
      case 'message':
        _openChat(d);
      case 'call':
        if ('${d['muted']}' == '1') {
          Calls.instance.openMutedFromNotification(d);
        }
    }
  }

  void _openChat(Map<String, dynamic> d) {
    final uid = '${d['fromUid'] ?? ''}';
    final chatId = '${d['chatId'] ?? ''}';
    final nav = Calls.instance.navigatorKey.currentState;
    if (uid.isEmpty || nav == null) return;
    if (ChatDetailScreen.openChatId == chatId) return; // already open
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => ChatDetailScreen(
          other: UserProfile(
            uid: uid,
            name: '',
            username: '${d['fromName'] ?? ''}',
            photoUrl: '${d['fromPhoto'] ?? ''}',
          ),
        ),
      ),
    );
  }

  /// App is open: Android shows no notification, so a small banner.
  void _banner(RemoteMessage m) {
    final d = m.data;
    if (d['type'] != 'message') return;
    final chatId = '${d['chatId'] ?? ''}';
    if (ChatDetailScreen.openChatId == chatId) return;
    if (ChatPrefs.instance.value.value.isMuted(chatId)) return;
    final ctx = Calls.instance.navigatorKey.currentContext;
    if (ctx == null) return;
    final messenger = ScaffoldMessenger.maybeOf(ctx);
    if (messenger == null) return;
    final title = m.notification?.title ?? '${d['fromName'] ?? ''}';
    final body = m.notification?.body ?? 'New message';
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
          content: Text(
            '$title: $body',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          action: SnackBarAction(
            label: 'Open',
            textColor: AppColors.lime,
            onPressed: () => _openChat(d),
          ),
        ),
      );
  }
}
