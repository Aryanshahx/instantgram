import 'package:cloud_firestore/cloud_firestore.dart';

/// The id of the chat between two people: both uids, in alphabetical order. The same two
/// people always get the same chat, whoever writes first.
String chatIdFor(String a, String b) =>
    a.compareTo(b) <= 0 ? '${a}_$b' : '${b}_$a';

/// The two uids of a chat, in the order stored in the `members` field.
List<String> chatMembers(String a, String b) =>
    a.compareTo(b) <= 0 ? [a, b] : [b, a];

/// A conversation in the inbox.
class ChatThread {
  const ChatThread({
    required this.id,
    required this.members,
    this.lastText = '',
    this.lastAt,
    this.lastSender = '',
    this.seen = const {},
  });

  final String id;
  final List<String> members;
  final String lastText;
  final DateTime? lastAt;
  final String lastSender;

  /// When each member last opened the chat.
  final Map<String, DateTime> seen;

  /// The other person.
  String other(String me) =>
      members.firstWhere((m) => m != me, orElse: () => me);

  /// A chat that exists but has no message yet is not shown in the inbox.
  bool get hasMessages => lastText.isNotEmpty;

  /// The last message is from the other person and was not opened yet.
  bool isUnread(String me) {
    if (!hasMessages || lastSender.isEmpty || lastSender == me) return false;
    final at = lastAt;
    if (at == null) return false;
    final s = seen[me];
    return s == null || s.isBefore(at);
  }

  factory ChatThread.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const <String, dynamic>{};
    final seenRaw = m['seen'];
    final lastAt = m['lastAt'];
    return ChatThread(
      id: d.id,
      members: m['members'] is List
          ? [
              for (final x in m['members'] as List)
                if (x is String) x,
            ]
          : const [],
      lastText: m['lastText'] is String ? m['lastText'] as String : '',
      lastAt: lastAt is Timestamp ? lastAt.toDate() : null,
      lastSender: m['lastSender'] is String ? m['lastSender'] as String : '',
      seen: seenRaw is Map
          ? {
              for (final e in seenRaw.entries)
                if (e.key is String && e.value is Timestamp)
                  e.key as String: (e.value as Timestamp).toDate(),
            }
          : const {},
    );
  }
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.text,
    required this.createdAt,
    this.pending = false,
  });

  final String id;
  final String senderId;
  final String text;
  final DateTime createdAt;

  /// Not confirmed by the server yet.
  final bool pending;

  factory ChatMessage.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const <String, dynamic>{};
    final at = m['createdAt'];
    return ChatMessage(
      id: d.id,
      senderId: m['senderId'] is String ? m['senderId'] as String : '',
      text: m['text'] is String ? m['text'] as String : '',
      createdAt: at is Timestamp ? at.toDate() : DateTime.now(),
      pending: d.metadata.hasPendingWrites,
    );
  }
}
