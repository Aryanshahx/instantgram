import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/services/api_client.dart';
import '../chats/data/chat_repository.dart';

/// The other person in a call.
class CallPeer {
  const CallPeer({required this.uid, required this.name, this.photoUrl = ''});
  final String uid;
  final String name;
  final String photoUrl;
}

enum CallPhase { ringing, connecting, connected, reconnecting, ended }

/// calls/{id}.status values.
abstract final class CallStatus {
  static const ringing = 'ringing';
  static const accepted = 'accepted';
  static const declined = 'declined';
  static const ended = 'ended';
  static const missed = 'missed';
  static const busy = 'busy';
  static const all = [ringing, accepted, declined, ended, missed, busy];
}

/// Text shown when a call ends.
String endText(String status, {required bool outgoing}) => switch (status) {
  CallStatus.declined => outgoing ? 'Call declined' : 'Call ended',
  CallStatus.missed => outgoing ? 'No answer' : 'Missed call',
  CallStatus.busy => 'Busy on another call',
  _ => 'Call ended',
};

/// One voice / video call (v0.10): WebRTC directly between the 2 phones,
/// Firestore carries the offer / answer / network candidates, Cloudflare
/// TURN helps when a direct connection is not possible.
class CallSession extends ChangeNotifier {
  CallSession._({
    required this.id,
    required this.me,
    required this.peer,
    required this.outgoing,
    required this.video,
  });

  /// How long a call rings before "No answer".
  static const Duration ringFor = Duration(seconds: 45);

  final String id;
  final String me;
  final CallPeer peer;
  final bool outgoing;
  final bool video;

  CallPhase phase = CallPhase.connecting;
  String? endReason;
  DateTime? connectedAt;
  bool muted = false;
  bool speaker = false;
  bool cameraOn = true;
  bool frontCamera = true;

  final RTCVideoRenderer localView = RTCVideoRenderer();
  final RTCVideoRenderer remoteView = RTCVideoRenderer();
  bool hasRemoteVideo = false;

  RTCPeerConnection? _pc;
  MediaStream? _local;
  bool _remoteSet = false;
  final List<RTCIceCandidate> _remoteQueue = [];
  final List<RTCIceCandidate> _localQueue = [];
  bool _docReady = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _docSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _candSub;
  Timer? _ringTimer;
  Timer? _lostTimer;
  bool _closed = false;

  /// v0.11 call log: last status we know, and whether it was answered.
  String _status = CallStatus.ringing;
  bool _accepted = false;
  bool _logged = false;
  bool _switching = false;
  final List<MediaStream> _extraStreams = [];

  /// v0.0.2: sends our camera; the new camera goes here after a flip.
  RTCRtpSender? _videoSender;

  static FirebaseFirestore get _db => FirebaseFirestore.instance;
  DocumentReference<Map<String, dynamic>> get _doc =>
      _db.collection('calls').doc(id);

  bool get ended => phase == CallPhase.ended;

  // ------------------------------------------------------------ start

  /// You call [peer].
  static Future<CallSession> startOutgoing({
    required String me,
    required String myName,
    required String myPhoto,
    required CallPeer peer,
    required bool video,
  }) async {
    final id = _db.collection('calls').doc().id;
    final s = CallSession._(
      id: id,
      me: me,
      peer: peer,
      outgoing: true,
      video: video,
    );
    s.phase = CallPhase.ringing;
    try {
      await s._setup();
      final offer = await s._pc!.createOffer({});
      await s._pc!.setLocalDescription(offer);
      await s._doc.set({
        'callerId': me,
        'callerName': myName,
        'callerPhoto': myPhoto,
        'calleeId': peer.uid,
        'calleeName': peer.name,
        'calleePhoto': peer.photoUrl,
        'video': video,
        'status': CallStatus.ringing,
        'offer': {'type': offer.type, 'sdp': offer.sdp},
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      await s._close();
      await s.disposeViews();
      rethrow;
    }
    s._docReady = true;
    s._flushLocal();
    s._listen();
    s._ringTimer = Timer(ringFor, () {
      if (s.phase == CallPhase.ringing) s.hangUp(status: CallStatus.missed);
    });
    // make the other phone ring (also when their app is closed)
    unawaited(s._push('ring'));
    try {
      await FlutterCallkitIncoming.startCall(
        CallKitParams(
          id: id,
          nameCaller: peer.name,
          appName: 'InstantGram',
          handle: video ? 'Video call' : 'Voice call',
          type: video ? 1 : 0,
          extra: {'peerId': peer.uid},
        ),
      );
    } catch (e) {
      debugPrint('callkit start: $e');
    }
    return s;
  }

  /// You accepted call [id].
  static Future<CallSession> answer({
    required String id,
    required String me,
  }) async {
    final snap = await _db.collection('calls').doc(id).get();
    final d = snap.data();
    if (d == null || d['calleeId'] != me) throw const CallGone();
    final s = CallSession._(
      id: id,
      me: me,
      peer: CallPeer(
        uid: '${d['callerId']}',
        name: '${d['callerName'] ?? ''}',
        photoUrl: '${d['callerPhoto'] ?? ''}',
      ),
      outgoing: false,
      video: d['video'] == true,
    );
    if (d['status'] != CallStatus.ringing) {
      s._finish(endText('${d['status']}', outgoing: false));
      return s;
    }
    try {
      await s._setup();
      s._docReady = true;
      final offer = d['offer'];
      if (offer is! Map) throw const CallGone();
      await s._pc!.setRemoteDescription(
        RTCSessionDescription('${offer['sdp']}', '${offer['type']}'),
      );
      s._remoteSet = true;
      final ans = await s._pc!.createAnswer({});
      await s._pc!.setLocalDescription(ans);
      await s._doc.update({
        'answer': {'type': ans.type, 'sdp': ans.sdp},
        'status': CallStatus.accepted,
        'acceptedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      await s._close();
      await s.disposeViews();
      // the caller should not keep ringing
      try {
        await s._doc.update({
          'status': CallStatus.ended,
          'endedAt': FieldValue.serverTimestamp(),
        });
      } catch (_) {}
      if (e is CallGone) rethrow;
      final t = '$e'.toLowerCase();
      if (t.contains('permission') || t.contains('notallowed')) rethrow;
      throw CallFailed('$e');
    }
    s._flushLocal();
    s._listen();
    return s;
  }

  Future<void> _setup() async {
    await Future.wait([localView.initialize(), remoteView.initialize()]);
    final ice = await IceServers.get();
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true},
      'video': video
          ? {
              'facingMode': 'user',
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
              'frameRate': {'ideal': 30},
            }
          : false,
    });
    localView.srcObject = _local;
    final pc = _pc = await createPeerConnection({
      'iceServers': ice,
      'sdpSemantics': 'unified-plan',
    });
    for (final t in _local!.getTracks()) {
      final sender = await pc.addTrack(t, _local!);
      if (t.kind == 'video') _videoSender = sender;
    }
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      if (_docReady) {
        _sendCandidate(c);
      } else {
        _localQueue.add(c);
      }
    };
    pc.onTrack = (e) {
      if (e.streams.isEmpty) return;
      remoteView.srcObject = e.streams.first;
      if (e.track.kind == 'video') hasRemoteVideo = true;
      notifyListeners();
    };
    pc.onConnectionState = _onState;
    speaker = video; // video calls: loudspeaker, voice: earpiece
    try {
      await Helper.setSpeakerphoneOn(speaker);
    } catch (_) {}
    try {
      await WakelockPlus.enable();
    } catch (_) {}
  }

  void _flushLocal() {
    for (final c in _localQueue) {
      _sendCandidate(c);
    }
    _localQueue.clear();
  }

  Future<void> _sendCandidate(RTCIceCandidate c) async {
    try {
      await _doc.collection('candidates').add({
        'from': me,
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('candidate: $e');
    }
  }

  void _listen() {
    _docSub = _doc.snapshots().listen((snap) async {
      final d = snap.data();
      if (d == null || _closed) return;
      final status = '${d['status']}';
      _status = status;
      if (status == CallStatus.accepted) _accepted = true;
      if (outgoing && status == CallStatus.accepted && !_remoteSet) {
        final a = d['answer'];
        if (a is Map) {
          _remoteSet = true;
          _ringTimer?.cancel();
          phase = CallPhase.connecting;
          notifyListeners();
          try {
            await _pc?.setRemoteDescription(
              RTCSessionDescription('${a['sdp']}', '${a['type']}'),
            );
            for (final c in _remoteQueue) {
              await _pc?.addCandidate(c);
            }
            _remoteQueue.clear();
          } catch (e) {
            debugPrint('answer: $e');
            hangUp(reason: 'Could not connect');
          }
        }
      }
      if (status != CallStatus.ringing && status != CallStatus.accepted) {
        _finish(endText(status, outgoing: outgoing));
      }
    }, onError: (Object e) => debugPrint('call doc: $e'));
    _candSub = _doc
        .collection('candidates')
        .where('from', isEqualTo: peer.uid)
        .snapshots()
        .listen((q) async {
          for (final ch in q.docChanges) {
            if (ch.type != DocumentChangeType.added) continue;
            final m = ch.doc.data();
            if (m == null) continue;
            final c = RTCIceCandidate(
              '${m['candidate']}',
              m['sdpMid'] as String?,
              (m['sdpMLineIndex'] as num?)?.toInt(),
            );
            if (_remoteSet) {
              try {
                await _pc?.addCandidate(c);
              } catch (e) {
                debugPrint('add candidate: $e');
              }
            } else {
              _remoteQueue.add(c);
            }
          }
        }, onError: (Object e) => debugPrint('candidates: $e'));
  }

  void _onState(RTCPeerConnectionState s) {
    if (_closed) return;
    switch (s) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _lostTimer?.cancel();
        if (connectedAt == null) {
          connectedAt = DateTime.now();
          FlutterCallkitIncoming.setCallConnected(id).catchError((_) {});
        }
        phase = CallPhase.connected;
        notifyListeners();
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        if (phase == CallPhase.connected) {
          phase = CallPhase.reconnecting;
          notifyListeners();
        }
        _lostTimer ??= Timer(const Duration(seconds: 15), () {
          if (phase != CallPhase.connected) hangUp(reason: 'Connection lost');
        });
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        hangUp(reason: connectedAt == null ? 'Could not connect' : 'Connection lost');
      default:
        break;
    }
  }

  // ------------------------------------------------------------ controls

  void toggleMute() {
    muted = !muted;
    for (final t in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    speaker = !speaker;
    notifyListeners();
    try {
      await Helper.setSpeakerphoneOn(speaker);
    } catch (_) {}
  }

  void toggleCamera() {
    cameraOn = !cameraOn;
    for (final t in _local?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = cameraOn;
    }
    notifyListeners();
  }

  /// Front <-> back camera. v0.11: when the phone's quick switch fails
  /// (some Oppo / Realme / Vivo phones), the camera is restarted on the
  /// other side and the new picture is sent instead.
  Future<void> switchCamera() async {
    final t = _local?.getVideoTracks();
    if (t == null || t.isEmpty || _switching || _closed) return;
    _switching = true;
    try {
      // v0.0.2: the phone answers "is the FRONT camera on now?" (not
      // "did it work"). v0.11 read false (front -> back) as a failure and
      // restarted the camera, so the other person saw a black / frozen
      // picture. Only a real error uses the restart now.
      final r = await quickSwitchResult(
        () => Helper.switchCamera(t.first),
        wasFront: frontCamera,
      );
      if (r == null) {
        await _replaceCamera(!frontCamera);
      } else {
        frontCamera = r;
      }
      notifyListeners();
    } finally {
      _switching = false;
    }
  }

  /// v0.0.2: result of the phone's quick switch: the side now in use,
  /// or null when it failed (then the camera is restarted). A slow phone
  /// (no answer in 8 s) is still switching: never restart over it.
  @visibleForTesting
  static Future<bool?> quickSwitchResult(
    Future<bool> Function() run, {
    required bool wasFront,
    Duration wait = const Duration(seconds: 8),
  }) async {
    try {
      return await run().timeout(wait);
    } on TimeoutException {
      return !wasFront;
    } catch (e) {
      debugPrint('switch camera: $e');
      return null;
    }
  }

  Future<void> _replaceCamera(bool front) async {
    final local = _local;
    final pc = _pc;
    if (local == null || pc == null) return;
    final old = local.getVideoTracks();
    Future<MediaStream> open(bool f) => navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {
        'facingMode': f ? 'user' : 'environment',
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
        'frameRate': {'ideal': 30},
      },
    });
    // most phones can't open 2 cameras at once: stop the old one first
    for (final o in old) {
      try {
        await o.stop();
      } catch (_) {}
    }
    MediaStream fresh;
    var side = front;
    try {
      fresh = await open(front);
    } catch (e) {
      debugPrint('camera $front: $e');
      side = !front;
      fresh = await open(side); // back to the camera we had
    }
    _extraStreams.add(fresh);
    final track = fresh.getVideoTracks().first;
    track.enabled = cameraOn;
    // v0.0.2: the video sender kept from the start (getSenders() on some
    // phones gives senders without their track, so nothing was replaced)
    final senders = <RTCRtpSender>[];
    final kept = _videoSender;
    if (kept != null) {
      senders.add(kept);
    } else {
      for (final tr in await pc.getTransceivers()) {
        final k = tr.sender.track?.kind ?? tr.receiver.track?.kind;
        if (k == 'video') senders.add(tr.sender);
      }
    }
    for (final sender in senders) {
      try {
        await sender.replaceTrack(track);
      } catch (e) {
        debugPrint('replace track: $e');
      }
    }
    for (final o in old) {
      try {
        await local.removeTrack(o);
      } catch (_) {}
    }
    try {
      await local.addTrack(track);
    } catch (_) {}
    localView.srcObject = fresh;
    frontCamera = side;
  }

  /// v0.11: "Voice call · 2:31" / "Missed video call" in the chat.
  /// The caller writes it (once).
  void _logCall() {
    if (!outgoing || _logged || debugNoCallLog) return;
    _logged = true;
    final at = connectedAt;
    final String status;
    var secs = 0;
    if (at != null) {
      status = 'ended';
      secs = DateTime.now().difference(at).inSeconds;
    } else if (_status == CallStatus.declined) {
      status = 'declined';
    } else if (_status == CallStatus.busy) {
      status = 'busy';
    } else if (_accepted) {
      status = 'failed';
    } else {
      status = 'missed';
    }
    unawaited(
      ChatRepository.instance
          .addCallLog(
            ChatPerson(uid: peer.uid, username: peer.name, photoUrl: peer.photoUrl),
            video: video,
            status: status,
            durationSec: secs,
          )
          .catchError((Object e) => debugPrint('call log: $e')),
    );
  }

  @visibleForTesting
  static bool debugNoCallLog = false;

  /// End button (or timeout / error).
  Future<void> hangUp({String status = CallStatus.ended, String? reason}) async {
    if (_closed) return;
    final wasRinging = phase == CallPhase.ringing;
    if (_status == CallStatus.ringing || _status == CallStatus.accepted) {
      _status = status;
    }
    _finish(reason ?? endText(status, outgoing: outgoing));
    try {
      await _doc.update({
        'status': status,
        'endedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('hang up: $e');
    }
    // the other phone may still ring (app closed): stop it
    if (outgoing && wasRinging) unawaited(_push('cancel'));
  }

  void _finish(String reason) {
    if (phase == CallPhase.ended) return;
    endReason = reason;
    phase = CallPhase.ended;
    notifyListeners();
    _logCall();
    _close();
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    _ringTimer?.cancel();
    _lostTimer?.cancel();
    await _docSub?.cancel();
    await _candSub?.cancel();
    try {
      for (final t in _local?.getTracks() ?? const <MediaStreamTrack>[]) {
        await t.stop();
      }
      await _local?.dispose();
      for (final x in _extraStreams) {
        for (final t in x.getTracks()) {
          await t.stop();
        }
        await x.dispose();
      }
      await _pc?.close();
    } catch (e) {
      debugPrint('close: $e');
    }
    try {
      await FlutterCallkitIncoming.endCall(id);
    } catch (_) {}
    try {
      await WakelockPlus.disable();
    } catch (_) {}
  }

  /// After the call screen is gone.
  bool _viewsGone = false;

  Future<void> disposeViews() async {
    if (_viewsGone) return;
    _viewsGone = true;
    try {
      localView.srcObject = null;
      remoteView.srcObject = null;
      await localView.dispose();
      await remoteView.dispose();
    } catch (_) {}
  }

  Future<void> _push(String action) async {
    try {
      await ApiClient.instance.post('/api/call-push', {
        'callId': id,
        'action': action,
      });
    } catch (e) {
      // ringing still works while their app is open (Firestore)
      debugPrint('call push: $e');
    }
  }
}

/// The call is over / not for you.
class CallGone implements Exception {
  const CallGone();
  @override
  String toString() => 'This call has ended.';
}

class CallFailed implements Exception {
  const CallFailed(this.detail);
  final String detail;
  @override
  String toString() => 'Could not connect the call.';
}

/// STUN / TURN servers. TURN comes from our server (Cloudflare), because
/// its passwords expire. Without it, Google + Cloudflare STUN is used
/// (works on most Wi-Fi, not always on mobile data).
abstract final class IceServers {
  static const fallback = [
    {
      'urls': [
        'stun:stun.cloudflare.com:3478',
        'stun:stun.l.google.com:19302',
      ],
    },
  ];

  static List<Map<String, dynamic>>? _cache;
  static DateTime? _at;

  static Future<List<Map<String, dynamic>>> get() async {
    final c = _cache;
    if (c != null && DateTime.now().difference(_at!) < const Duration(hours: 2)) {
      return c;
    }
    try {
      final r = await ApiClient.instance
          .post('/api/turn', {})
          .timeout(const Duration(seconds: 6));
      final list = parse(r['iceServers']);
      if (list.isNotEmpty) {
        _cache = list;
        _at = DateTime.now();
        return list;
      }
    } catch (e) {
      debugPrint('turn: $e');
    }
    return fallback;
  }

  /// Keeps only well-formed entries.
  @visibleForTesting
  static List<Map<String, dynamic>> parse(Object? v) {
    if (v is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final e in v) {
      if (e is! Map) continue;
      final urls = e['urls'];
      final list = urls is String
          ? [urls]
          : urls is List
          ? urls.whereType<String>().toList()
          : const <String>[];
      if (list.isEmpty) continue;
      out.add({
        'urls': list,
        if (e['username'] is String) 'username': e['username'],
        if (e['credential'] is String) 'credential': e['credential'],
      });
    }
    return out;
  }
}
