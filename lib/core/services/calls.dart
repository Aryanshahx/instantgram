import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/calls/call_ringer.dart';
import '../../features/calls/call_screen.dart';
import '../../features/calls/call_session.dart';
import '../../firebase_options.dart';

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
      _token = await fm.getToken();
      if (_token != null) await _saveToken(uid, _token!);
      _tokenSub ??= fm.onTokenRefresh.listen((t) {
        _token = t;
        _saveToken(uid, t);
      });
      // app open: the push rings here too (no second ring: same call id)
      _msgSub ??= FirebaseMessaging.onMessage.listen((m) {
        final id = '${m.data['callId'] ?? ''}';
        if (m.data['type'] == 'call' && (_rang.contains(id) || inCall)) {
          return;
        }
        if (m.data['type'] == 'call') _rang.add(id);
        CallRinger.onPush(m.data);
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
      await ref.set({'tokens': list, 'updatedAt': FieldValue.serverTimestamp()});
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
            if (t is Timestamp &&
                DateTime.now().difference(t.toDate()).inMilliseconds >
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

  /// Decline (also from the closed app).
  static Future<void> decline(String id) async {
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
