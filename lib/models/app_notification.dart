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
    this.title = '',
  });

  /// Messages from the InstantGram team (admin panel): a heading ('' = none).
  final String title;

  /// From the InstantGram team: a message ('admin') or a warning ('warning').
  bool get isFromTeam => type == 'admin' || type == 'warning';

  /// 'like', 'super' (super heart), 'comment', 'reply', 'follow' or 'mention'.
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
      title: m['title'] is String ? m['title'] as String : '',
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
      case 'super':
        return 'sent you a super heart 💖';
      case 'comment':
        return 'commented';
      case 'reply':
        return 'replied';
      case 'mention':
        return 'mentioned you';
      case 'follow':
        return 'started following you';
      case 'story_view':
        return 'viewed your moment';
      case 'story_like':
        return 'liked your moment';
      case 'story_super':
        return 'sent your moment a super heart 💖';
      case 'admin':
        return title.isEmpty ? '' : title;
      case 'warning':
        return 'Warning';
      default:
        return 'interacted with your post';
    }
  }

  bool get isFollow => type == 'follow';

  bool get isStoryView => type.startsWith('story_');
}

/// Empty list helper (keeps the stream contract simple in tests).
const List<AppNotification> kNoNotifications = <AppNotification>[];
