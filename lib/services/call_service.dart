import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../models/call.dart';
import 'call_engine.dart';
import 'user_service.dart';
import 'push_service.dart';

/// Where the ringing documents live. The real one is Firestore; tests use a fake.
abstract class CallBackend {
  Future<CallInfo> place(String callerId, String calleeUid, bool video);
  Stream<CallInfo?> watch(String id);
  Future<void> setStatus(String id, String status);
  Stream<List<CallInfo>> watchRinging(String myUid);
}

class FirestoreCallBackend implements CallBackend {
  FirebaseFirestore get _db => FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _calls =>
      _db.collection('calls');

  @override
  Future<CallInfo> place(String callerId, String calleeUid, bool video) async {
    final ref = _calls.doc();
    await ref.set({
      'callerId': callerId,
      'calleeId': calleeUid,
      'video': video,
      'status': CallStatus.ringing,
      'createdAt': FieldValue.serverTimestamp(),
    });
    PushService.instance.call(
      ref.id,
    ); // rings the phone even when the app is closed
    return CallInfo(
      id: ref.id,
      callerId: callerId,
      calleeId: calleeUid,
      video: video,
      status: CallStatus.ringing,
    );
  }

  @override
  Stream<CallInfo?> watch(String id) => _calls
      .doc(id)
      .snapshots()
      .map((d) => d.exists ? CallInfo.fromDoc(d) : null);

  @override
  Future<void> setStatus(String id, String status) => _calls.doc(id).update({
    'status': status,
    if (status == CallStatus.accepted)
      'answeredAt': FieldValue.serverTimestamp(),
    if (CallStatus.isOver(status)) 'endedAt': FieldValue.serverTimestamp(),
  });

  @override
  Stream<List<CallInfo>> watchRinging(String myUid) => _calls
      .where('calleeId', isEqualTo: myUid)
      .where('status', isEqualTo: CallStatus.ringing)
      .snapshots()
      .map((s) => s.docs.map(CallInfo.fromDoc).toList());
}

/// Calls between two people. The "ringing" is a small document that both phones watch:
///
///   calls/{id}   callerId, calleeId, video, status, createdAt, answeredAt, endedAt
///
/// The audio and video themselves travel through [CallEngine].
class CallService {
  CallService._();
  static final CallService instance = CallService._();

  /// Replaced in tests.
  CallBackend backend = FirestoreCallBackend();

  /// My uid (replaced in tests).
  String Function() myUid = () => UserService.instance.myUid;

  String get _me => myUid();

  /// A call that is ringing for me right now (null when none).
  final ValueNotifier<CallInfo?> incoming = ValueNotifier(null);

  /// I am in a call (so a second call does not pop up over it).
  bool busy = false;

  StreamSubscription<List<CallInfo>>? _sub;

  /// Starts listening for calls to me (once; called by the main screen).
  void start() {
    if (_sub != null) return;
    _sub = backend.watchRinging(_me).listen((list) {
      final now = DateTime.now();
      final fresh = list.where((c) => c.isFresh(now)).toList()
        ..sort((a, b) => (b.createdAt ?? now).compareTo(a.createdAt ?? now));
      incoming.value = fresh.isEmpty ? null : fresh.first;
    }, onError: (Object _) => incoming.value = null);
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    incoming.value = null;
  }

  /// Rings [calleeUid]. Returns the call (its id is the room).
  Future<CallInfo> place(String calleeUid, {required bool video}) =>
      backend.place(_me, calleeUid, video);

  Stream<CallInfo?> watch(String id) => backend.watch(id);

  /// Moves the call to [status]. Never throws (a call must still end when the network is
  /// bad).
  Future<void> setStatus(String id, String status) async {
    try {
      await backend.setStatus(id, status);
    } catch (_) {
      // the other side will time out
    }
  }
}

/// The ring (incoming) and the "calling..." tone (outgoing) plus vibration. Uses the app's
/// own sound files and the native video player, so no extra plugin is needed.
class CallTone {
  CallTone({required this.incoming});

  final bool incoming;
  VideoPlayerController? _c;
  Timer? _buzz;
  bool _stopped = false;

  Future<void> start() async {
    if (!CallDeps.tones) return;
    if (incoming) {
      void buzz() => HapticFeedback.vibrate();
      buzz();
      _buzz = Timer.periodic(const Duration(milliseconds: 1800), (_) => buzz());
    }
    final c = VideoPlayerController.asset(
      incoming ? 'assets/sounds/ring.mp3' : 'assets/sounds/calling.mp3',
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    try {
      await c.initialize();
      await c.setLooping(true);
      await c.setVolume(1);
      if (_stopped) {
        await c.dispose();
        return;
      }
      _c = c;
      await c.play();
    } catch (_) {
      await c.dispose();
    }
  }

  Future<void> stop() async {
    _stopped = true;
    _buzz?.cancel();
    _buzz = null;
    final c = _c;
    _c = null;
    try {
      await c?.dispose();
    } catch (_) {
      // already gone
    }
  }
}
