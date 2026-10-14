import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

/// Shows the full-screen "incoming call" (v0.10). Works from the push
/// message handler too (app closed), so it uses no Firestore / no UI.
abstract final class CallRinger {
  /// A push older than this is ignored (the call is over anyway).
  static const int maxAgeMs = 45000;

  static CallKitParams params({
    required String id,
    required String name,
    required String callerId,
    required bool video,
    String photo = '',
  }) {
    return CallKitParams(
      id: id,
      nameCaller: name.isEmpty ? 'InstantGram user' : name,
      appName: 'InstantGram',
      avatar: photo.startsWith('http') ? photo : null,
      handle: video ? 'Video call' : 'Voice call',
      type: video ? 1 : 0,
      duration: maxAgeMs,
      missedCallNotification: const NotificationParams(
        showNotification: true,
        isShowCallback: true,
        subtitle: 'Missed call',
        callbackText: 'Call back',
      ),
      extra: {
        'callerId': callerId,
        'callerName': name,
        'callerPhoto': photo,
        'video': video ? '1' : '0',
      },
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#0F1115',
        actionColor: '#C6FF3D',
        textColor: '#FFFFFF',
        incomingCallNotificationChannelName: 'Incoming calls',
        missedCallNotificationChannelName: 'Missed calls',
        isShowFullLockedScreen: true,
        isImportant: true,
        textAccept: 'Accept',
        textDecline: 'Decline',
      ),
    );
  }

  /// FCM data message from our server: {type: call | call_cancel, ...}.
  static Future<void> onPush(Map<String, dynamic> data) async {
    final id = '${data['callId'] ?? ''}';
    if (id.isEmpty) return;
    final p = params(
      id: id,
      name: '${data['callerName'] ?? ''}',
      callerId: '${data['callerId'] ?? ''}',
      photo: '${data['callerPhoto'] ?? ''}',
      video: '${data['video']}' == '1',
    );
    try {
      switch (data['type']) {
        case 'call':
          final sent = int.tryParse('${data['sentAt'] ?? ''}') ?? 0;
          final age = DateTime.now().millisecondsSinceEpoch - sent;
          if (sent > 0 && age > maxAgeMs) return; // arrived too late
          await show(p);
        case 'call_cancel':
          // caller hung up before you answered
          final active = await FlutterCallkitIncoming.activeCalls();
          final wasRinging = active.any((c) => c.id == id && !c.isAccepted);
          await FlutterCallkitIncoming.endCall(id);
          if (wasRinging) {
            await FlutterCallkitIncoming.showMissCallNotification(p);
          }
      }
    } catch (e) {
      debugPrint('ringer: $e');
    }
  }

  /// Rings, unless this call is already shown.
  static Future<void> show(CallKitParams p) async {
    try {
      final active = await FlutterCallkitIncoming.activeCalls();
      if (active.any((c) => c.id == p.id)) return;
    } catch (_) {}
    await FlutterCallkitIncoming.showCallkitIncoming(p);
  }

  /// Values from an event back to a plain map.
  static Map<String, dynamic> extra(CallKitParams p) {
    final e = p.extra;
    if (e == null) return const {};
    return {for (final k in e.keys) k: e[k]};
  }
}
