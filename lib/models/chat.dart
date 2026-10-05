import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/media_url.dart';

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

/// What a message contains.
class MsgType {
  static const text = 'text';
  static const image = 'image';
  static const gif = 'gif';
  static const voice = 'voice';
  static const location = 'location';
  static const post = 'post';
  static const all = [text, image, gif, voice, location, post];
}

/// The emoji people can react with.
const List<String> kReactions = [
  '\u2764\ufe0f',
  '\u{1F602}',
  '\u{1F62E}',
  '\u{1F622}',
  '\u{1F64F}',
  '\u{1F44D}',
];

/// A short text for a message (inbox line, reply quote, pinned banner).
String messagePreview(
  String type,
  String text, {
  bool postIsClip = false,
  bool deleted = false,
}) {
  if (deleted) return 'Message deleted';
  switch (type) {
    case MsgType.image:
      return '\u{1F4F7} Photo';
    case MsgType.gif:
      return 'GIF';
    case MsgType.voice:
      return '\u{1F3A4} Voice message';
    case MsgType.location:
      return '\u{1F4CD} Location';
    case MsgType.post:
      return postIsClip ? '\u{1F3AC} Clip' : '\u{1F5BC} Post';
    default:
      return text;
  }
}

/// The message another message answers (stored inside the answer, so it still shows when
/// the original is deleted).
class ReplyRef {
  const ReplyRef({
    required this.id,
    required this.senderId,
    required this.kind,
    required this.preview,
  });

  final String id;
  final String senderId;
  final String kind;
  final String preview;

  Map<String, dynamic> toMap() => {
    'id': id,
    'senderId': senderId,
    'kind': kind,
    'preview': preview.length > 120 ? preview.substring(0, 120) : preview,
  };

  static ReplyRef? fromMap(Object? v) {
    if (v is! Map) return null;
    String s(Object? x) => x is String ? x : '';
    final id = s(v['id']);
    if (id.isEmpty) return null;
    return ReplyRef(
      id: id,
      senderId: s(v['senderId']),
      kind: s(v['kind']).isEmpty ? MsgType.text : s(v['kind']),
      preview: s(v['preview']),
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
    this.type = MsgType.text,
    this.mediaRef = '',
    this.width = 0,
    this.height = 0,
    this.duration = 0,
    this.lat = 0,
    this.lng = 0,
    this.postId = '',
    this.postThumbRef = '',
    this.postTitle = '',
    this.postAuthor = '',
    this.postIsClip = false,
    this.replyTo,
    this.forwarded = false,
    this.reactions = const {},
    this.hiddenFor = const [],
    this.deleted = false,
    this.pinned = false,
    this.pinnedBy = '',
  });

  final String id;
  final String senderId;
  final String text;
  final DateTime createdAt;

  /// Not confirmed by the server yet.
  final bool pending;

  /// One of [MsgType].
  final String type;

  /// Photo, GIF or voice file: `m:<key>` of our own storage, or a plain https link (GIFs).
  final String mediaRef;
  final int width;
  final int height;

  /// Voice message length in seconds.
  final int duration;
  final double lat;
  final double lng;

  /// A shared post or clip.
  final String postId;
  final String postThumbRef;
  final String postTitle;
  final String postAuthor;
  final bool postIsClip;

  final ReplyRef? replyTo;
  final bool forwarded;

  /// uid -> emoji
  final Map<String, String> reactions;

  /// People who removed the message from their own view ("delete for me").
  final List<String> hiddenFor;
  final bool deleted;
  final bool pinned;
  final String pinnedBy;

  String get mediaUrl => resolveMediaUrl(mediaRef);
  String get postThumbUrl => resolveMediaUrl(postThumbRef);
  double get aspect => (width > 0 && height > 0) ? width / height : 1;

  String get preview =>
      messagePreview(type, text, postIsClip: postIsClip, deleted: deleted);

  bool visibleFor(String uid) => !hiddenFor.contains(uid);

  /// emoji -> how many people used it
  Map<String, int> get reactionCounts {
    final out = <String, int>{};
    for (final e in reactions.values) {
      out[e] = (out[e] ?? 0) + 1;
    }
    return out;
  }

  factory ChatMessage.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const <String, dynamic>{};
    final at = m['createdAt'];
    String s(Object? v) => v is String ? v : '';
    int i(Object? v) => v is num ? v.toInt() : 0;
    double f(Object? v) => v is num ? v.toDouble() : 0;
    final type = MsgType.all.contains(s(m['type']))
        ? s(m['type'])
        : MsgType.text;
    final rx = m['reactions'];
    final hidden = m['hiddenFor'];
    return ChatMessage(
      id: d.id,
      senderId: s(m['senderId']),
      text: s(m['text']),
      createdAt: at is Timestamp ? at.toDate() : DateTime.now(),
      pending: d.metadata.hasPendingWrites,
      type: type,
      mediaRef: s(m['mediaUrl']),
      width: i(m['width']),
      height: i(m['height']),
      duration: i(m['duration']),
      lat: f(m['lat']),
      lng: f(m['lng']),
      postId: s(m['postId']),
      postThumbRef: s(m['postThumb']),
      postTitle: s(m['postTitle']),
      postAuthor: s(m['postAuthor']),
      postIsClip: m['postIsClip'] == true,
      replyTo: ReplyRef.fromMap(m['replyTo']),
      forwarded: m['forwarded'] == true,
      reactions: rx is Map
          ? {
              for (final e in rx.entries)
                if (e.key is String && e.value is String)
                  e.key as String: e.value as String,
            }
          : const {},
      hiddenFor: hidden is List
          ? [
              for (final x in hidden)
                if (x is String) x,
            ]
          : const [],
      deleted: m['deleted'] == true,
      pinned: m['pinned'] == true,
      pinnedBy: s(m['pinnedBy']),
    );
  }
}
