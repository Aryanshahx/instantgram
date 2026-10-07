import 'package:cloud_firestore/cloud_firestore.dart';

/// One line of the activity screen: someone liked, commented, replied or followed.
///
/// There are no push notifications, so this is what the bell in Discover shows while the
/// app is open.
class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    this.actorId = '',
    this.actorName = '',
    this.actorPhoto = '',
    this.postId = '',
    this.thumb = '',
    this.text = '',
    this.createdAt,
    this.read = false,
  });

  /// 'like', 'comment', 'reply', 'follow' or 'mention'.
  final String type;

  final String id;
  final String actorId;
  final String actorName;
  final String actorPhoto;

  /// The post this is about (empty for a follow).
  final String postId;

  /// Small picture of the post (empty when there is none).
  final String thumb;

  /// The comment text (only for 'comment', 'reply' and 'mention').
  final String text;

  final DateTime? createdAt;
  final bool read;

  factory AppNotification.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const <String, dynamic>{};
    DateTime? at;
    final ts = m['at'];
    if (ts is Timestamp) at = ts.toDate();
    return AppNotification(
      id: d.id,
      type: m['type'] is String ? m['type'] as String : '',
      actorId: m['actorId'] is String ? m['actorId'] as String : '',
      actorName: m['actorName'] is String ? m['actorName'] as String : '',
      actorPhoto: m['actorPhoto'] is String ? m['actorPhoto'] as String : '',
      postId: m['postId'] is String ? m['postId'] as String : '',
      thumb: m['thumb'] is String ? m['thumb'] as String : '',
      text: m['text'] is String ? m['text'] as String : '',
      createdAt: at,
      read: m['read'] == true,
    );
  }

  Map<String, dynamic> get toMap => <String, dynamic>{
    'type': type,
    'actorId': actorId,
    'actorName': actorName,
    'actorPhoto': actorPhoto,
    'postId': postId,
    'thumb': thumb,
    'text': text,
    'at': FieldValue.serverTimestamp(),
    'read': read,
  };

  /// "liked your post", "commented: ...", "started following you".
  String get verb {
    switch (type) {
      case 'like':
        return 'liked your post';
      case 'comment':
        return 'commented';
      case 'reply':
        return 'replied';
      case 'mention':
        return 'mentioned you';
      case 'follow':
        return 'started following you';
      default:
        return 'interacted with your post';
    }
  }

  bool get isFollow => type == 'follow';
}

/// Empty list helper (keeps the stream contract simple in tests).
const List<AppNotification> kNoNotifications = <AppNotification>[];
