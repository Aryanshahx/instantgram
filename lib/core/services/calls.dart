import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zego_uikit/zego_uikit.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';
import 'package:zego_uikit_signaling_plugin/zego_uikit_signaling_plugin.dart';

import 'api_client.dart';

/// ZEGOCLOUD keys, from the server (Vercel: ZEGO_APP_ID, ZEGO_APP_SIGN,
/// ZEGO_RESOURCE_ID).
class CallConfig {
  const CallConfig({
    required this.appID,
    required this.appSign,
    this.resourceID = '',
  });

  final int appID;
  final String appSign;

  /// Push resource id: the phone rings even when the app is closed.
  final String resourceID;

  bool get valid =>
      appID > 0 && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(appSign);

  Map<String, dynamic> toJson() => {
    'appID': appID,
    'appSign': appSign,
    'resourceID': resourceID,
  };

  static CallConfig? fromJson(Object? v) {
    if (v is! Map) return null;
    final c = CallConfig(
      appID: (v['appID'] as num?)?.toInt() ?? 0,
      appSign: (v['appSign'] as String?)?.trim() ?? '',
      resourceID: (v['resourceID'] as String?)?.trim() ?? '',
    );
    return c.valid ? c : null;
  }
}

/// Calls are not set up on the server yet.
class CallsOff implements Exception {
  const CallsOff();
  @override
  String toString() =>
      'Calls are not set up yet. Add the ZEGOCLOUD keys in Vercel.';
}

/// Voice + video calls (v0.9) with ZEGOCLOUD Call Kit:
///  * [prepare] in main() (before the app starts)
///  * [signIn] after login, every app start (receives calls)
///  * [call] from a chat
///  * [signOut] before logging out
/// Incoming calls ring with a full screen notification, also when the
/// app is closed (needs the push resource id + Firebase file, see README).
class Calls {
  Calls._();
  static final Calls instance = Calls._();

  /// Tests: never touch the ZEGOCLOUD plugins.
  static bool disabled = false;

  static const _prefsKey = 'call_config_v1';

  /// The app's navigator (call screens open on it).
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  CallConfig? _cfg;
  String _uid = '';
  String _name = '';
  bool _ready = false;
  Future<void>? _starting;

  bool get ready => _ready;

  /// Before runApp: lets an accepted call (from the notification) open.
  Future<void> prepare() async {
    if (disabled) return;
    try {
      ZegoUIKitPrebuiltCallInvitationService().setNavigatorKey(navigatorKey);
      await ZegoUIKit().initLog();
      await ZegoUIKitPrebuiltCallInvitationService().useSystemCallingUI([
        ZegoUIKitSignalingPlugin(),
      ]);
    } catch (e) {
      debugPrint('calls: prepare failed: $e');
    }
  }

  /// After login. Never throws (calls just stay off when not set up).
  Future<void> signIn({required String uid, required String username}) {
    if (disabled || uid.isEmpty) return Future.value();
    if (_ready && _uid == uid) return Future.value();
    return _starting ??= _signIn(uid, username).whenComplete(
      () => _starting = null,
    );
  }

  Future<void> _signIn(String uid, String username) async {
    _uid = uid;
    _name = username.isEmpty ? 'InstantGram user' : username;
    final cached = await _cached();
    final cfg = cached ?? await _fetch();
    if (cfg == null || _uid != uid) return;
    await _init(cfg);
    // keys may have changed on the server: check once in the background
    if (cached != null) unawaited(_recheck(cached));
  }

  Future<void> _init(CallConfig cfg) async {
    try {
      if (_ready) await ZegoUIKitPrebuiltCallInvitationService().uninit();
      await ZegoUIKitPrebuiltCallInvitationService().init(
        appID: cfg.appID,
        appSign: cfg.appSign,
        userID: _uid,
        userName: _name,
        plugins: [ZegoUIKitSignalingPlugin()],
        requireConfig: (data) => data.type == ZegoCallInvitationType.videoCall
            ? ZegoUIKitPrebuiltCallConfig.oneOnOneVideoCall()
            : ZegoUIKitPrebuiltCallConfig.oneOnOneVoiceCall(),
        config: ZegoCallInvitationConfig(
          // the app opens the accepted call itself, after the home screen
          offline: ZegoCallInvitationOfflineConfig(
            autoEnterAcceptedOfflineCall: false,
          ),
        ),
        notificationConfig: ZegoCallInvitationNotificationConfig(
          androidNotificationConfig: ZegoCallAndroidNotificationConfig(
            showOnLockedScreen: false,
            showOnFullScreen: true,
            callIDVisibility: false,
            callChannel: ZegoCallAndroidNotificationChannelConfig(
              channelID: 'instantgram_calls',
              channelName: 'Calls',
              sound: 'call',
            ),
            missedCallChannel: ZegoCallAndroidNotificationChannelConfig(
              channelID: 'instantgram_missed_calls',
              channelName: 'Missed calls',
              vibrate: false,
            ),
          ),
        ),
      );
      _cfg = cfg;
      _ready = true;
    } catch (e) {
      debugPrint('calls: init failed: $e');
      _ready = false;
    }
  }

  /// Call accepted from the notification while the app was closed:
  /// open it once the home screen is there.
  void openAcceptedCall() {
    if (disabled || !_ready) return;
    try {
      ZegoUIKitPrebuiltCallInvitationService().enterAcceptedOfflineCall();
    } catch (e) {
      debugPrint('calls: enterAcceptedOfflineCall: $e');
    }
  }

  /// Starts a voice / video call. Throws [CallsOff] when calls are not set
  /// up on the server, or a [StateError] with a friendly message.
  Future<void> call({
    required String uid,
    required String username,
    required bool video,
  }) async {
    if (disabled) throw const CallsOff();
    if (!_ready && _uid.isNotEmpty) {
      // maybe the keys were added after the app started
      final cfg = await _fetch();
      if (cfg != null) await _init(cfg);
    }
    final cfg = _cfg;
    if (!_ready || cfg == null) throw const CallsOff();
    final ok = await ZegoUIKitPrebuiltCallInvitationService().send(
      invitees: [ZegoCallUser(uid, username.isEmpty ? 'user' : username)],
      isVideoCall: video,
      resourceID: cfg.resourceID.isEmpty ? null : cfg.resourceID,
      notificationTitle: _name,
      notificationMessage: video
          ? 'Incoming video call…'
          : 'Incoming voice call…',
    );
    if (!ok) throw StateError("Couldn't start the call. Try again.");
  }

  /// Before logging out (stops incoming calls for this account).
  Future<void> signOut() async {
    if (disabled) return;
    _uid = '';
    if (!_ready) return;
    _ready = false;
    try {
      await ZegoUIKitPrebuiltCallInvitationService().uninit();
    } catch (e) {
      debugPrint('calls: uninit failed: $e');
    }
  }

  // ---------------------------------------------------------------- keys

  Future<CallConfig?> _cached() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_prefsKey);
      if (raw == null) return null;
      return CallConfig.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// Keys from the server (null when calls are off or no internet).
  Future<CallConfig?> _fetch() async {
    try {
      final data = await ApiClient.instance.post('/api/call-config', {});
      final cfg = CallConfig.fromJson(data);
      final p = await SharedPreferences.getInstance();
      if (cfg == null) {
        await p.remove(_prefsKey);
      } else {
        await p.setString(_prefsKey, jsonEncode(cfg.toJson()));
      }
      return cfg;
    } on ApiException catch (e) {
      if (e.statusCode == 503 || e.statusCode == 404) {
        final p = await SharedPreferences.getInstance();
        await p.remove(_prefsKey);
      }
      debugPrint('calls: config: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('calls: config: $e');
      return null;
    }
  }

  Future<void> _recheck(CallConfig old) async {
    final now = await _fetch();
    if (now == null || _uid.isEmpty) return;
    if (now.appID != old.appID ||
        now.appSign != old.appSign ||
        now.resourceID != old.resourceID) {
      await _init(now);
    }
  }
}
