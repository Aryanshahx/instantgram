import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../core/media_url.dart';

/// Push notifications on the phone (Firebase Cloud Messaging).
///
/// Sending: after a message, a call or a like is written, the app asks the media signer
/// (`POST /notify`) to tell the other person's phones. The signer reads the real item from
/// Firestore and writes the text itself.
///
/// Receiving: this phone's address (the FCM token) is kept in `pushTokens/{me}.tokens`.
/// Android shows the notification when the app is closed or in the background; while the app
/// is open nothing pops up (the app shows it already). A tap lands in [opened].
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  /// Tests replace the network call (and get the bodies that would be sent).
  Future<void> Function(Map<String, dynamic> body)? sendBackend;

  /// The data of the notification the user tapped (`type`: message / call / activity, `from`,
  /// `chatId`, `postId`). The main screen opens the right place and sets it back to null.
  final ValueNotifier<Map<String, String>?> opened = ValueNotifier(null);

  final Dio _api = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );

  StreamSubscription<String>? _refreshSub;
  StreamSubscription<RemoteMessage>? _openSub;
  StreamSubscription<RemoteMessage>? _fgSub;

  /// A notification that came while the app is open (Android does not show those itself):
  /// the main screen shows it as a banner.
  final ValueNotifier<({String title, String body, String type})?> shown =
      ValueNotifier(null);
  String _token = '';
  String _uid = '';

  static bool get _firebaseReady {
    try {
      return Firebase.apps.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------------ sending

  /// A chat message was sent (call it after the message is stored).
  void message(String chatId, String messageId) =>
      _send({'kind': 'message', 'chatId': chatId, 'messageId': messageId});

  /// I am calling someone (the call document is stored and ringing).
  void call(String callId) => _send({'kind': 'call', 'callId': callId});

  /// I watched a moment for the first time (the signer tells the author only if they asked
  /// to hear about me).
  void storyView(String storyId, {bool limited = false}) =>
      _send({'kind': 'storyView', 'storyId': storyId, if (limited) 'col': 'p'});

  /// A like / comment / follow line was written into [to]'s Notifications.
  void activity(String to, String itemId) =>
      _send({'kind': 'activity', 'to': to, 'itemId': itemId});

  /// Never throws and never makes the sender wait: a missing push is not worth an error.
  void _send(Map<String, dynamic> body) {
    unawaited(_post(body));
  }

  Future<void> _post(Map<String, dynamic> body) async {
    try {
      final b = sendBackend;
      if (b != null) {
        await b(body);
        return;
      }
      if (!_firebaseReady || !mediaServerConfigured) return;
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken() ?? '';
      await _api.post<dynamic>(
        '$mediaApiBase/notify',
        data: body,
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
    } catch (_) {
      // best effort
    }
  }

  // ---------------------------------------------------------------- receiving

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      FirebaseFirestore.instance.collection('pushTokens').doc(uid);

  /// After login (main screen): asks for permission, stores this phone's address and listens
  /// for taps. Does nothing in tests.
  Future<void> start() async {
    if (sendBackend != null || !_firebaseReady) return;
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty || uid == _uid) return;
    _uid = uid;
    try {
      final fm = FirebaseMessaging.instance;
      await fm.requestPermission();
      final t = await fm.getToken() ?? '';
      if (t.isNotEmpty) await _save(t);
      await _refreshSub?.cancel();
      _refreshSub = fm.onTokenRefresh.listen(_save);
      await _openSub?.cancel();
      _openSub = FirebaseMessaging.onMessageOpenedApp.listen(_tapped);
      await _fgSub?.cancel();
      _fgSub = FirebaseMessaging.onMessage.listen((m) {
        final n = m.notification;
        if (n == null) return;
        shown.value = (
          title: n.title ?? 'InstantGram',
          body: n.body ?? '',
          type: '${m.data['type'] ?? ''}',
        );
      });
      final first = await fm.getInitialMessage();
      if (first != null) _tapped(first);
    } catch (_) {
      // no Google Play services, no network...: the app works without push
    }
  }

  Future<void> _save(String token) async {
    final old = _token;
    _token = token;
    if (_uid.isEmpty) return;
    try {
      await _doc(_uid).set({
        'tokens': FieldValue.arrayUnion([token]),
        'at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      if (old.isNotEmpty && old != token) {
        await _doc(_uid).update({
          'tokens': FieldValue.arrayRemove([old]),
        });
      }
    } catch (_) {
      // next start
    }
  }

  void _tapped(RemoteMessage m) {
    opened.value = {for (final e in m.data.entries) e.key: '${e.value}'};
  }

  /// Before logging out: this phone stops getting this account's notifications.
  Future<void> stop() async {
    final uid = _uid;
    final token = _token;
    _uid = '';
    await _refreshSub?.cancel();
    await _openSub?.cancel();
    await _fgSub?.cancel();
    _refreshSub = null;
    _openSub = null;
    _fgSub = null;
    if (uid.isEmpty || token.isEmpty || !_firebaseReady) return;
    try {
      await _doc(uid)
          .update({
            'tokens': FieldValue.arrayRemove([token]),
          })
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // the signer drops dead addresses by itself
    }
  }

  /// Settings > Notifications > Send a test: registers this phone again and asks the signer
  /// to notify my own phones. Returns what happened, in words.
  Future<({bool ok, String detail})> sendTest() async {
    if (!_firebaseReady) return (ok: false, detail: 'Firebase is not ready.');
    if (!mediaServerConfigured) {
      return (
        ok: false,
        detail: 'The media signer is not set up in this build.',
      );
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return (ok: false, detail: 'Log in first.');
    try {
      final fm = FirebaseMessaging.instance;
      final perm = await fm.requestPermission();
      if (perm.authorizationStatus == AuthorizationStatus.denied) {
        return (
          ok: false,
          detail:
              'Notifications are blocked for InstantGram. Turn them on in Android Settings > Apps > InstantGram > Notifications.',
        );
      }
      final t = await fm.getToken() ?? '';
      if (t.isEmpty) {
        return (
          ok: false,
          detail:
              'This phone got no notification address (Google Play services missing?).',
        );
      }
      _uid = user.uid;
      await _save(t);
      final id = await user.getIdToken() ?? '';
      final r = await _api.post<dynamic>(
        '$mediaApiBase/notify',
        data: {'kind': 'test'},
        options: Options(
          headers: {'Authorization': 'Bearer $id'},
          validateStatus: (_) => true,
        ),
      );
      final body = r.data is Map ? r.data as Map : const {};
      final detail = '${body['detail'] ?? ''}';
      if (r.statusCode == 404) {
        return (
          ok: false,
          detail: 'The signer is an old version. Redeploy it in Vercel.',
        );
      }
      if (r.statusCode != 200) {
        return (
          ok: false,
          detail: detail.isEmpty
              ? 'The signer answered ${r.statusCode}.'
              : detail,
        );
      }
      return (
        ok: body['ok'] == true,
        detail: detail.isEmpty ? 'Sent.' : detail,
      );
    } catch (e) {
      return (ok: false, detail: 'Could not reach the signer: $e');
    }
  }

  /// Settings > Notifications: all push off (still shown inside the app).
  Future<bool> isOff() async {
    if (!_firebaseReady) return false;
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return false;
    try {
      final d = await _doc(uid).get();
      return d.data()?['off'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> setOff(bool off) async {
    if (!_firebaseReady) return;
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;
    await _doc(uid).set({'off': off}, SetOptions(merge: true));
  }
}
