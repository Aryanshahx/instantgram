import 'package:cloud_firestore/cloud_firestore.dart';

/// Where a call is.
class CallStatus {
  static const ringing = 'ringing';
  static const accepted = 'accepted';
  static const declined = 'declined';
  static const ended = 'ended';
  static const missed = 'missed';
  static const all = [ringing, accepted, declined, ended, missed];

  /// The call is over (nobody can join it any more).
  static bool isOver(String s) => s == declined || s == ended || s == missed;
}

/// A call ring older than this is ignored (the caller probably closed the app).
const Duration kCallFreshness = Duration(seconds: 75);

/// How long the caller waits for an answer.
const Duration kRingTimeout = Duration(seconds: 45);

/// One call, stored in Firestore as `calls/{id}`. The call id is also the audio/video room.
class CallInfo {
  const CallInfo({
    required this.id,
    required this.callerId,
    required this.calleeId,
    required this.video,
    required this.status,
    this.createdAt,
  });

  final String id;
  final String callerId;
  final String calleeId;
  final bool video;
  final String status;
  final DateTime? createdAt;

  /// The room both phones join.
  String get channel => id;

  String other(String me) => me == callerId ? calleeId : callerId;

  /// Still worth ringing for.
  bool isFresh(DateTime now) {
    final at = createdAt;
    if (at == null) return true; // just created on this phone
    return now.difference(at) < kCallFreshness;
  }

  factory CallInfo.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const <String, dynamic>{};
    String s(Object? v) => v is String ? v : '';
    final at = m['createdAt'];
    final status = s(m['status']);
    return CallInfo(
      id: d.id,
      callerId: s(m['callerId']),
      calleeId: s(m['calleeId']),
      video: m['video'] == true,
      status: CallStatus.all.contains(status) ? status : CallStatus.ended,
      createdAt: at is Timestamp ? at.toDate() : null,
    );
  }
}

/// "Voice call", "Missed video call", ... for the chat and the inbox line.
String callLabel({required bool video, required String status}) {
  final kind = video ? 'video call' : 'voice call';
  switch (status) {
    case CallStatus.missed:
      return 'Missed $kind';
    case CallStatus.declined:
      return video ? 'Video call declined' : 'Voice call declined';
    default:
      return video ? 'Video call' : 'Voice call';
  }
}

/// 75 -> "1:15", 3700 -> "1:01:40".
String formatCallTime(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}
