import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/calls/call_ringer.dart';
import '../../features/calls/call_screen.dart';
import '../../features/calls/call_session.dart';
import '../../features/calls/incoming_call_screen.dart';
import '../../firebase_options.dart';
import 'chat_prefs.dart';
import 'server_clock.dart';
import 'system_settings.dart';

/// v0.11 Settings -> Calls check: what this phone allows.
class CallCheck {
  const CallCheck({
    required this.notifications,
    required this.fullScreen,
    required this.battery,
    required this.registered,
  });

  /// Notifications allowed (needed for ringing + messages).
  final bool notifications;

  /// Android 14+: the call can show over the lock screen.
  final bool fullScreen;

  /// No battery limits (the phone does not kill the app's push).
  final bool battery;

  /// This phone is saved for push (our server can reach it).
  final bool registered;

  bool get allGood => notifications && fullScreen && battery && registered;
}

/// Calls can't start (tests, or already in a call).
class CallsOff implements Exception {
  const CallsOff([this.message = 'Calls are off.']);
  final String message;
  @override
  String toString() => message;
}

/// Push message while the app is in the background or CLOSED: ring.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage m) async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (_) {}
  await CallRinger.onPush(m.data);
}

/// "Decline" pressed while the app was closed: tell the caller.
@pragma('vm:entry-point')
Future<void> callkitBackgroundHandler(CallEvent e) async {
  if (e is! CallEventActionCallDecline) return;
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await Calls.decline(e.callKitParams.id);
  } catch (err) {
    debugPrint('decline in background: $err');
  }
}

/// Voice + video calls (v0.10): own WebRTC calls (see [CallSession]).
///
/// - You call: a calls/{id} doc is made and our server sends a push, so
///   the other phone rings even when the app is closed.
/// - While the app is open, new calls are also seen from Firestore.
/// - Accept / Decline come from the full-screen call UI.
class Calls {
  Calls._();
  static final Calls instance = Calls._();

  /// Tests: no plugins / Firestore.
  static bool disabled = false;

  /// The app's navigator (call screens open on it).
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  String? _me;
  String _myName = '';
  String _myPhoto = '';
  CallSession? _session;
  String? _screenFor; // call id of the open call screen
  StreamSubscription<CallEvent?>? _events;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _incoming;
  StreamSubscription<String>? _tokenSub;
  StreamSubscription<RemoteMessage>? _msgSub;
  String? _token;
  final Set<String> _rang = {};

  bool get ready => _me != null;
  bool get inCall => _session != null && !_session!.ended;

  static DocumentReference<Map<String, dynamic>> _call(String id) =>
      FirebaseFirestore.instance.collection('calls').doc(id);

  /// Before runApp.
  Future<void> prepare() async {
    if (disabled) return;
    try {
      FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);
      await FlutterCallkitIncoming.onBackgroundMessage(
        callkitBackgroundHandler,
      );
    } catch (e) {
      debugPrint('calls prepare: $e');
    }
  }

  /// After login.
  Future<void> signIn({
    required String uid,
    required String username,
    String photoUrl = '',
  }) async {
    if (disabled) return;
    _me = uid;
    _myName = username;
    _myPhoto = photoUrl;
    _events ??= FlutterCallkitIncoming.onEvent.listen(_onEvent);
    _listenIncoming(uid);
    unawaited(_registerPush(uid));
  }

  // ------------------------------------------------------------ push token

  Future<void> _registerPush(String uid) async {
    try {
      final fm = FirebaseMessaging.instance;
      await fm.requestPermission();
      // v0.11: asked at login too (before: only when YOU called someone,
      // so calls to you could not show over the lock screen)
      await _askFullScreenOnce();
      _token = await fm.getToken();
      if (_token != null) await _saveToken(uid, _token!);
      _tokenSub ??= fm.onTokenRefresh.listen((t) {
        _token = t;
        _saveToken(uid, t);
      });
      // app open: the push rings here too (no second ring: same call id)
      _msgSub ??= FirebaseMessaging.onMessage.listen((m) {
        final d = m.data;
        final type = d['type'];
        final id = '${d['callId'] ?? ''}';
        if (type == 'call' || type == 'call_test') {
          if (_rang.contains(id) || inCall) return;
          _rang.add(id);
          if (CallRinger.isMuted(d)) {
            _showMuted(id, _peerOf(d), video: '${d['video']}' == '1');
            return;
          }
          CallRinger.onPush(d);
        } else if (type == 'call_cancel') {
          CallRinger.onPush(d);
        }
      });
    } catch (e) {
      debugPrint('push: $e');
    }
  }

  /// pushTokens/{uid} = {tokens: [last 5 phones]} (only you can read it;
  /// our server reads it to ring you).
  static Future<void> _saveToken(String uid, String token) async {
    final ref = FirebaseFirestore.instance.collection('pushTokens').doc(uid);
    try {
      final cur = (await ref.get()).data()?['tokens'];
      final list = <String>[
        if (cur is List) ...cur.whereType<String>().where((t) => t != token),
      ];
      while (list.length > 4) {
        list.removeAt(0);
      }
      list.add(token);
      await ref.set({
        'tokens': list,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('push token: $e');
    }
  }

  // ------------------------------------------------------------ incoming

  void _listenIncoming(String uid) {
    _incoming?.cancel();
    _incoming = FirebaseFirestore.instance
        .collection('calls')
        .where('calleeId', isEqualTo: uid)
        .where('status', isEqualTo: CallStatus.ringing)
        .snapshots()
        .listen((q) {
          for (final ch in q.docChanges) {
            final id = ch.doc.id;
            final d = ch.doc.data() ?? const <String, dynamic>{};
            if (ch.type == DocumentChangeType.removed) {
              // stopped ringing (caller hung up / timeout / answered)
              if (_screenFor != id) {
                FlutterCallkitIncoming.endCall(id).catchError((_) {});
              }
              continue;
            }
            if (ch.type != DocumentChangeType.added || _rang.contains(id)) {
              continue;
            }
            final t = d['createdAt'];
            // v0.11: server time (a wrong phone clock skipped real calls)
            if (t is Timestamp &&
                ServerClock.now().difference(t.toDate()).inMilliseconds >
                    CallRinger.maxAgeMs) {
              continue; // old, never answered
            }
            if (inCall) {
              _call(id).update({'status': CallStatus.busy}).catchError((_) {});
              continue;
            }
            _rang.add(id);
            // in the background the push rings (avoids ringing twice)
            final state = WidgetsBinding.instance.lifecycleState;
            if (state != null && state != AppLifecycleState.resumed) continue;
            final callerId = '${d['callerId'] ?? ''}';
            if (ChatPrefs.instance.value.value.callsMuted(callerId)) {
              // v0.11: muted = silent call screen, no ringing
              _showMuted(
                id,
                CallPeer(
                  uid: callerId,
                  name: '${d['callerName'] ?? ''}',
                  photoUrl: '${d['callerPhoto'] ?? ''}',
                ),
                video: d['video'] == true,
              );
              continue;
            }
            CallRinger.show(
              CallRinger.params(
                id: id,
                name: '${d['callerName'] ?? ''}',
                callerId: '${d['callerId'] ?? ''}',
                photo: '${d['callerPhoto'] ?? ''}',
                video: d['video'] == true,
              ),
            ).catchError((Object e) => debugPrint('ring: $e'));
          }
        }, onError: (Object e) => debugPrint('incoming calls: $e'));
  }

  void _onEvent(CallEvent? e) {
    switch (e) {
      case CallEventActionCallAccept(:final callKitParams):
        _openAnswer(callKitParams);
      case CallEventActionCallDecline(:final callKitParams):
        decline(callKitParams.id);
      case CallEventActionCallEnded(:final callKitParams):
        final s = _session;
        if (s != null && s.id == callKitParams.id && !s.ended) s.hangUp();
      case CallEventActionCallCallback(:final id):
        _callBack(id);
      default:
        break;
    }
  }

  static CallPeer _peerOf(Map<String, dynamic> d) => CallPeer(
    uid: '${d['callerId'] ?? ''}',
    name: '${d['callerName'] ?? ''}',
    photoUrl: '${d['callerPhoto'] ?? ''}',
  );

  String? _mutedFor; // call id of the open silent call screen

  /// v0.11: silent call screen for a muted caller.
  void _showMuted(String id, CallPeer peer, {required bool video}) {
    final nav = navigatorKey.currentState;
    final me = _me;
    if (nav == null || me == null || _mutedFor == id || _screenFor != null) {
      return;
    }
    _mutedFor = id;
    nav
        .push(
          MaterialPageRoute<void>(
            builder: (ctx) => IncomingCallScreen(
              callId: id,
              peer: peer,
              video: video,
              onDecline: () => decline(id),
              onAccept: () {
                Navigator.of(ctx).pop();
                _open(
                  id,
                  peer,
                  video: video,
                  outgoing: false,
                  start: () => CallSession.answer(id: id, me: me),
                );
              },
            ),
          ),
        )
        .whenComplete(() {
          if (_mutedFor == id) _mutedFor = null;
        });
  }

  /// v0.11: the quiet "Voice call from X" notification was tapped.
  Future<void> openMutedFromNotification(Map<String, dynamic> d) async {
    final id = '${d['callId'] ?? ''}';
    if (disabled || _me == null || id.isEmpty || inCall) return;
    try {
      final snap = await _call(id).get();
      if (snap.data()?['status'] != CallStatus.ringing) return; // over
      _showMuted(id, _peerOf(d), video: '${d['video']}' == '1');
    } catch (e) {
      debugPrint('muted call: $e');
    }
  }

  /// Decline (also from the closed app).
  static Future<void> decline(String id) async {
    if (CallRinger.isTest(id)) return;
    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final ref = _call(id);
        final snap = await tx.get(ref);
        if (snap.data()?['status'] != CallStatus.ringing) return;
        tx.update(ref, {
          'status': CallStatus.declined,
          'endedAt': FieldValue.serverTimestamp(),
        });
      });
    } catch (e) {
      debugPrint('decline: $e');
    }
  }

  /// "Call back" on a missed call notification.
  Future<void> _callBack(String id) async {
    try {
      final d = (await _call(id).get()).data();
      if (d == null) return;
      await call(
        uid: '${d['callerId']}',
        username: '${d['callerName'] ?? ''}',
        photoUrl: '${d['callerPhoto'] ?? ''}',
        video: d['video'] == true,
      );
    } catch (e) {
      debugPrint('call back: $e');
    }
  }

  /// Accept pressed (app open, or the app was opened by Accept).
  void _openAnswer(CallKitParams p) {
    if (CallRinger.isTest(p.id)) {
      _testAnswered(p.id);
      return;
    }
    final me = _me;
    if (me == null || _screenFor == p.id) return;
    final x = CallRinger.extra(p);
    _open(
      p.id,
      CallPeer(
        uid: '${x['callerId'] ?? ''}',
        name: p.nameCaller ?? '${x['callerName'] ?? ''}',
        photoUrl: '${x['callerPhoto'] ?? ''}',
      ),
      video: p.type == 1,
      outgoing: false,
      start: () => CallSession.answer(id: p.id, me: me),
    );
  }

  /// The app was opened by Accept: open that call.
  Future<void> openAcceptedCall() async {
    if (disabled || _me == null) return;
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      for (final c in calls) {
        if (c.isAccepted && _screenFor != c.id) {
          _openAnswer(c);
          break;
        }
      }
    } catch (e) {
      debugPrint('accepted call: $e');
    }
  }

  // ------------------------------------------------------------ outgoing

  /// Starts a voice / video call to [uid].
  Future<void> call({
    required String uid,
    required String username,
    required bool video,
    String photoUrl = '',
  }) async {
    if (disabled) throw const CallsOff();
    final me = _me;
    if (me == null) throw const CallsOff('Calls are starting… try again.');
    if (uid == me) throw const CallsOff("You can't call yourself.");
    if (inCall || _screenFor != null) {
      throw const CallsOff('You are already in a call.');
    }
    await _askFullScreenOnce();
    _open(
      null,
      CallPeer(uid: uid, name: username, photoUrl: photoUrl),
      video: video,
      outgoing: true,
      start: () => CallSession.startOutgoing(
        me: me,
        myName: _myName,
        myPhoto: _myPhoto,
        peer: CallPeer(uid: uid, name: username, photoUrl: photoUrl),
        video: video,
      ),
    );
  }

  void _open(
    String? id,
    CallPeer peer, {
    required bool video,
    required bool outgoing,
    required Future<CallSession> Function() start,
  }) {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    _screenFor = id ?? 'outgoing';
    nav
        .push(
          MaterialPageRoute<void>(
            builder: (_) => CallScreen(
              peer: peer,
              video: video,
              outgoing: outgoing,
              start: () async {
                final s = await start();
                _session = s;
                _screenFor = s.id;
                return s;
              },
            ),
          ),
        )
        .whenComplete(() {
          _screenFor = null;
          _session = null;
        });
  }

  // ------------------------------------------------------------ v0.11 check

  /// The test call was answered: everything works.
  void _testAnswered(String id) {
    FlutterCallkitIncoming.endCall(id).catchError((_) {});
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    showDialog<void>(
      context: ctx,
      builder: (d) => AlertDialog(
        icon: const Icon(
          Icons.check_circle,
          color: Color(0xFF3DDC84),
          size: 44,
        ),
        title: const Text('Ringing works'),
        content: const Text('Calls to you will ring on this phone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// What this phone allows (Settings -> Calls check).
  Future<CallCheck> check() async {
    if (disabled) {
      return const CallCheck(
        notifications: false,
        fullScreen: false,
        battery: false,
        registered: false,
      );
    }
    var notifications = false;
    var fullScreen = true;
    var battery = true;
    try {
      final s = await FirebaseMessaging.instance.getNotificationSettings();
      notifications =
          s.authorizationStatus == AuthorizationStatus.authorized ||
          s.authorizationStatus == AuthorizationStatus.provisional;
    } catch (_) {}
    try {
      fullScreen = await FlutterCallkitIncoming.canUseFullScreenIntent();
    } catch (_) {}
    try {
      battery = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    } catch (_) {}
    if (_token == null && _me != null) {
      try {
        _token = await FirebaseMessaging.instance.getToken();
        if (_token != null) await _saveToken(_me!, _token!);
      } catch (_) {}
    }
    return CallCheck(
      notifications: notifications,
      fullScreen: fullScreen,
      battery: battery,
      registered: _token != null,
    );
  }

  /// v0.17: the two things every user MUST allow (the app waits on a
  /// "please allow" page until both are on).
  Future<({bool notifications, bool lockScreen})> mustHave() async {
    if (disabled) return (notifications: true, lockScreen: true);
    var notifications = false;
    var lockScreen = true;
    try {
      final s = await FirebaseMessaging.instance.getNotificationSettings();
      notifications =
          s.authorizationStatus == AuthorizationStatus.authorized ||
          s.authorizationStatus == AuthorizationStatus.provisional;
    } catch (_) {
      notifications = true; // can't check -> don't lock the app
    }
    try {
      lockScreen = await FlutterCallkitIncoming.canUseFullScreenIntent();
    } catch (_) {}
    return (notifications: notifications, lockScreen: lockScreen);
  }

  Future<void> fixNotifications() async {
    try {
      final s = await FirebaseMessaging.instance.requestPermission();
      if (s.authorizationStatus != AuthorizationStatus.authorized) {
        await SystemSettings.notifications();
      }
    } catch (_) {
      await SystemSettings.notifications();
    }
  }

  Future<void> fixFullScreen() async {
    try {
      await FlutterCallkitIncoming.requestFullIntentPermission();
    } catch (_) {}
  }

  Future<void> fixBattery() async {
    try {
      final ok = await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      if (!ok) {
        await FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
      }
    } catch (_) {
      await SystemSettings.app();
    }
  }

  /// Android 14+: the incoming call can only show full screen with this
  /// permission. Asked once.
  Future<void> _askFullScreenOnce() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getBool('asked_full_screen') == true) return;
      await p.setBool('asked_full_screen', true);
      if (!await FlutterCallkitIncoming.canUseFullScreenIntent()) {
        await FlutterCallkitIncoming.requestFullIntentPermission();
      }
    } catch (_) {}
  }

  /// Before logging out: this phone stops ringing for this account.
  Future<void> signOut() async {
    if (disabled) return;
    final me = _me;
    _me = null;
    await _incoming?.cancel();
    _incoming = null;
    await _tokenSub?.cancel();
    _tokenSub = null;
    await _msgSub?.cancel();
    _msgSub = null;
    final t = _token;
    if (me != null && t != null) {
      try {
        await FirebaseFirestore.instance.collection('pushTokens').doc(me).set({
          'tokens': FieldValue.arrayRemove([t]),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (_) {}
    }
    try {
      await FlutterCallkitIncoming.endAllCalls();
    } catch (_) {}
  }
}

/// v0.12: texts for the call check (testable).
class CallsText {
  CallsText._();

  /// The server says exactly what is wrong with FIREBASE_SERVICE_ACCOUNT.
  static String notSetUp(String serverMessage) {
    final m = serverMessage.trim();
    final why = m.contains('FIREBASE_SERVICE_ACCOUNT')
        ? m
        : 'FIREBASE_SERVICE_ACCOUNT on Vercel is missing or wrong.';
    return '$why\n\nFix: Firebase console -> Project settings -> Service '
        'accounts -> Generate new private key. Open the .json file, copy '
        'ALL of it into Vercel -> Settings -> Environment Variables -> '
        'FIREBASE_SERVICE_ACCOUNT (Production), then Redeploy.';
  }
}
