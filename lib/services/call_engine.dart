import 'dart:async';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/agora_key.dart';
import 'chat_service.dart';

/// The audio/video connection of one call. The screens only talk to this interface, so tests
/// can use a fake one and the real one (Agora) can be swapped without touching the screens.
abstract class CallEngine {
  /// This phone joined the room.
  final ValueNotifier<bool> joined = ValueNotifier(false);

  /// The other person is in the room (the call is connected).
  final ValueNotifier<bool> remoteJoined = ValueNotifier(false);

  /// The other person has left the room.
  final ValueNotifier<bool> remoteLeft = ValueNotifier(false);

  /// The other person's camera is sending pictures.
  final ValueNotifier<bool> remoteVideoOn = ValueNotifier(false);

  /// A problem the person should see (null = fine).
  final ValueNotifier<String?> error = ValueNotifier(null);

  Future<void> join({required String channel, required bool video});
  Future<void> setMuted(bool muted);
  Future<void> setSpeaker(bool on);
  Future<void> setCameraOn(bool on);
  Future<void> switchCamera();

  /// The other person's picture.
  Widget remoteView();

  /// My own camera picture.
  Widget localView();

  /// Leaves the room and frees the microphone and camera. Safe to call twice.
  Future<void> leave();
}

/// What went wrong when a call could not start, in words the person (or you) can act on.
/// Shows the real cause instead of a general "check your connection".
String callFailureMessage(Object e) {
  if (e is FirebaseException) {
    switch (e.code) {
      case 'permission-denied':
        return 'Calls are blocked by your Firestore rules. Open Firebase Console > '
            'Firestore Database > Rules, paste the file firebase/firestore.rules from '
            'the project and press Publish. Then try again.';
      case 'unavailable':
      case 'deadline-exceeded':
        return 'Could not reach the server. Check your internet connection and try again.';
      case 'unauthenticated':
        return 'Please log out and log in again, then try the call.';
      case 'failed-precondition':
        return 'Firestore needs an index for calls (${e.message ?? e.code}).';
    }
    return 'Firestore refused the call (${e.code}).';
  }
  if (e is AgoraRtcException) {
    switch (e.code) {
      case -101:
        return 'The Agora App ID is not valid. Run: bash tools/set_agora_id.sh YOUR_REAL_APP_ID';
      case -102:
        return 'Agora refused the room name.';
      case -109:
      case -110:
      case -17:
        return 'Agora wants a token: in console.agora.io open your project and use '
            '"Testing mode: APP ID" (no certificate), then run bash tools/set_agora_id.sh again.';
      case -3:
      case -7:
        return 'The calling engine did not start (code ${e.code}). Close the app fully and try again.';
    }
    return 'The calling engine stopped (code ${e.code}${(e.message ?? '').isEmpty ? '' : ': ${e.message}'}).';
  }
  final text = e.toString().replaceFirst(
    RegExp(r'^[A-Za-z]*Exception:? ?'),
    '',
  );
  final short = text.length > 140 ? '${text.substring(0, 140)}...' : text;
  return 'Could not start the call: $short';
}

/// Things the call screens need from the phone. Tests replace them.
class CallDeps {
  CallDeps._();

  static CallEngine Function() engine = AgoraCallEngine.new;

  /// Asks for the microphone (and the camera for video). True when allowed.
  static Future<bool> Function(bool video) permissions = _askPermissions;

  /// Play the ring and calling sounds and vibrate.
  static bool tones = true;

  /// Keep the screen on during a call.
  static bool keepAwake = true;

  /// Writes the "Voice call 2:31" line in the chat (the caller only).
  static Future<void> Function(
    String peerUid,
    bool video,
    String status,
    int seconds,
  )
  writeLog = _writeLog;

  static Future<void> _writeLog(
    String peerUid,
    bool video,
    String status,
    int seconds,
  ) => ChatService.instance.sendCallLog(
    peerUid,
    video: video,
    status: status,
    seconds: seconds,
  );

  /// Is calling set up (an Agora App ID is saved)?
  static bool Function() configured = () => kAgoraAppId.isNotEmpty;

  static Future<bool> _askPermissions(bool video) async {
    final need = <Permission>[
      Permission.microphone,
      if (video) Permission.camera,
    ];
    final result = await need.request();
    return result.values.every((s) => s.isGranted || s.isLimited);
  }

  static Future<void> screenOn(bool on) async {
    if (!keepAwake) return;
    try {
      if (on) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {
      // not important
    }
  }
}

/// The real thing: Agora's voice and video engine (works through mobile networks and Wi-Fi).
class AgoraCallEngine extends CallEngine {
  RtcEngine? _engine;
  RtcEngineEventHandler? _handler;
  VideoViewController? _remote;
  VideoViewController? _local;
  String _channel = '';
  int _remoteUid = 0;
  bool _video = false;
  bool _left = false;

  @override
  Future<void> join({required String channel, required bool video}) async {
    _channel = channel;
    _video = video;
    final e = createAgoraRtcEngine();
    _engine = e;
    await e.initialize(RtcEngineContext(appId: kAgoraAppId));
    _handler = RtcEngineEventHandler(
      onError: (ErrorCodeType err, String msg) {
        if (err == ErrorCodeType.errInvalidAppId ||
            err == ErrorCodeType.errInvalidToken ||
            err == ErrorCodeType.errTokenExpired) {
          error.value =
              'The Agora App ID is not valid for testing mode. Check it with: bash tools/set_agora_id.sh';
        }
      },
      onJoinChannelSuccess: (RtcConnection c, int elapsed) {
        joined.value = true;
      },
      onUserJoined: (RtcConnection c, int uid, int elapsed) {
        _remoteUid = uid;
        remoteLeft.value = false;
        remoteJoined.value = true;
      },
      onUserOffline: (RtcConnection c, int uid, UserOfflineReasonType why) {
        if (uid == _remoteUid) remoteLeft.value = true;
      },
      onRemoteVideoStateChanged:
          (
            RtcConnection c,
            int uid,
            RemoteVideoState state,
            RemoteVideoStateReason why,
            int elapsed,
          ) {
            if (uid != _remoteUid && _remoteUid != 0) return;
            _remoteUid = uid;
            remoteVideoOn.value =
                state == RemoteVideoState.remoteVideoStateDecoding;
          },
      onConnectionLost: (RtcConnection c) {
        error.value = 'Connection lost. Trying to reconnect...';
      },
      onRejoinChannelSuccess: (RtcConnection c, int elapsed) {
        error.value = null;
      },
    );
    e.registerEventHandler(_handler!);

    await e.enableAudio();
    if (video) {
      await e.enableVideo();
      await e.startPreview();
    }
    await e.setDefaultAudioRouteToSpeakerphone(video);
    await e.joinChannel(
      token: '',
      channelId: channel,
      uid: 0,
      options: ChannelMediaOptions(
        channelProfile: ChannelProfileType.channelProfileCommunication,
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        publishMicrophoneTrack: true,
        publishCameraTrack: video,
        autoSubscribeAudio: true,
        autoSubscribeVideo: video,
      ),
    );
  }

  @override
  Future<void> setMuted(bool muted) async =>
      _engine?.muteLocalAudioStream(muted);

  @override
  Future<void> setSpeaker(bool on) async => _engine?.setEnableSpeakerphone(on);

  @override
  Future<void> setCameraOn(bool on) async {
    final e = _engine;
    if (e == null || !_video) return;
    await e.enableLocalVideo(on);
    await e.muteLocalVideoStream(!on);
  }

  @override
  Future<void> switchCamera() async => _engine?.switchCamera();

  @override
  Widget remoteView() {
    final e = _engine;
    if (e == null || _remoteUid == 0) return const SizedBox.shrink();
    _remote ??= VideoViewController.remote(
      rtcEngine: e,
      canvas: VideoCanvas(
        uid: _remoteUid,
        renderMode: RenderModeType.renderModeHidden,
      ),
      connection: RtcConnection(channelId: _channel),
    );
    return AgoraVideoView(controller: _remote!);
  }

  @override
  Widget localView() {
    final e = _engine;
    if (e == null) return const SizedBox.shrink();
    _local ??= VideoViewController(
      rtcEngine: e,
      canvas: const VideoCanvas(
        uid: 0,
        renderMode: RenderModeType.renderModeHidden,
      ),
    );
    return AgoraVideoView(controller: _local!);
  }

  @override
  Future<void> leave() async {
    if (_left) return;
    _left = true;
    final e = _engine;
    _engine = null;
    if (e == null) return;
    try {
      if (_handler != null) e.unregisterEventHandler(_handler!);
      if (_video) await e.stopPreview();
      await e.leaveChannel();
      await e.release();
    } catch (_) {
      // already gone
    }
  }
}
