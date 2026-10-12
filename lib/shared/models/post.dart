import 'package:cloud_firestore/cloud_firestore.dart';

DateTime _date(Object? v) =>
    v is Timestamp ? v.toDate() : DateTime.now();
int _int(Object? v) => v is num ? v.toInt() : 0;
String _str(Object? v) => v is String ? v : '';

/// A photo post or a clip (short video).
class Post {
  const Post({
    required this.id,
    required this.authorId,
    required this.authorUsername,
    required this.authorPhotoUrl,
    required this.type,
    required this.mediaUrl,
    required this.mediaKey,
    required this.caption,
    required this.aspectRatio,
    required this.likesCount,
    required this.commentsCount,
    required this.repostsCount,
    required this.viewsCount,
    required this.pinned,
    required this.createdAt,
  });

  static const String photo = 'photo';
  static const String clip = 'clip';

  final String id;
  final String authorId;
  final String authorUsername;
  final String authorPhotoUrl;
  final String type;
  final String mediaUrl;
  final String mediaKey;
  final String caption;

  /// width / height
  final double aspectRatio;
  final int likesCount;
  final int commentsCount;
  final int repostsCount;
  final int viewsCount;
  final bool pinned;
  final DateTime createdAt;

  bool get isClip => type == clip;

  factory Post.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? const <String, dynamic>{};
    final ar = m['aspectRatio'];
    return Post(
      id: doc.id,
      authorId: _str(m['authorId']),
      authorUsername: _str(m['authorUsername']),
      authorPhotoUrl: _str(m['authorPhotoUrl']),
      type: _str(m['type']).isEmpty ? photo : _str(m['type']),
      mediaUrl: _str(m['mediaUrl']),
      mediaKey: _str(m['mediaKey']),
      caption: _str(m['caption']),
      aspectRatio: ar is num && ar > 0 ? ar.toDouble() : 1,
      likesCount: _int(m['likesCount']),
      commentsCount: _int(m['commentsCount']),
      repostsCount: _int(m['repostsCount']),
      viewsCount: _int(m['viewsCount']),
      pinned: m['pinned'] == true,
      createdAt: _date(m['createdAt']),
    );
  }
}

class Comment {
  const Comment({
    required this.id,
    required this.authorId,
    required this.authorUsername,
    required this.authorPhotoUrl,
    required this.text,
    required this.createdAt,
  });

  final String id;
  final String authorId;
  final String authorUsername;
  final String authorPhotoUrl;
  final String text;
  final DateTime createdAt;

  factory Comment.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? const <String, dynamic>{};
    return Comment(
      id: doc.id,
      authorId: _str(m['authorId']),
      authorUsername: _str(m['authorUsername']),
      authorPhotoUrl: _str(m['authorPhotoUrl']),
      text: _str(m['text']),
      createdAt: _date(m['createdAt']),
    );
  }
}

class Story {
  const Story({
    required this.id,
    required this.authorId,
    required this.authorUsername,
    required this.authorPhotoUrl,
    required this.mediaUrl,
    required this.mediaKey,
    required this.createdAt,
  });

  final String id;
  final String authorId;
  final String authorUsername;
  final String authorPhotoUrl;
  final String mediaUrl;
  final String mediaKey;
  final DateTime createdAt;

  factory Story.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? const <String, dynamic>{};
    return Story(
      id: doc.id,
      authorId: _str(m['authorId']),
      authorUsername: _str(m['authorUsername']),
      authorPhotoUrl: _str(m['authorPhotoUrl']),
      mediaUrl: _str(m['mediaUrl']),
      mediaKey: _str(m['mediaKey']),
      createdAt: _date(m['createdAt']),
    );
  }
}

/// All active stories of one user.
class StoryGroup {
  StoryGroup(this.authorId, this.stories);
  final String authorId;
  final List<Story> stories;

  String get username => stories.first.authorUsername;
  String get photoUrl => stories.first.authorPhotoUrl;
}

class Chat {
  const Chat({
    required this.id,
    required this.members,
    required this.memberInfo,
    required this.lastMessage,
    required this.lastSenderId,
    required this.updatedAt,
  });

  final String id;
  final List<String> members;
  final Map<String, dynamic> memberInfo;
  final String lastMessage;
  final String lastSenderId;
  final DateTime updatedAt;

  String otherUid(String me) =>
      members.firstWhere((m) => m != me, orElse: () => me);

  Map<String, dynamic> _info(String uid) {
    final v = memberInfo[uid];
    return v is Map<String, dynamic> ? v : const {};
  }

  String usernameOf(String uid) => _str(_info(uid)['username']);
  String photoOf(String uid) => _str(_info(uid)['photoUrl']);

  factory Chat.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? const <String, dynamic>{};
    final info = m['memberInfo'];
    return Chat(
      id: doc.id,
      members: List<String>.from((m['members'] as List?) ?? const []),
      memberInfo: info is Map<String, dynamic> ? info : const {},
      lastMessage: _str(m['lastMessage']),
      lastSenderId: _str(m['lastSenderId']),
      updatedAt: _date(m['updatedAt']),
    );
  }
}

class Message {
  const Message({
    required this.id,
    required this.senderId,
    required this.text,
    required this.createdAt,
  });

  final String id;
  final String senderId;
  final String text;
  final DateTime createdAt;

  factory Message.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? const <String, dynamic>{};
    return Message(
      id: doc.id,
      senderId: _str(m['senderId']),
      text: _str(m['text']),
      createdAt: _date(m['createdAt']),
    );
  }
}

class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.fromUid,
    required this.fromUsername,
    required this.fromPhotoUrl,
    required this.postId,
    required this.postThumb,
    required this.text,
    required this.read,
    required this.createdAt,
  });

  static const like = 'like';
  static const comment = 'comment';
  static const follow = 'follow';
  static const repost = 'repost';

  final String id;
  final String type;
  final String fromUid;
  final String fromUsername;
  final String fromPhotoUrl;
  final String postId;
  final String postThumb;
  final String text;
  final bool read;
  final DateTime createdAt;

  factory AppNotification.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? const <String, dynamic>{};
    return AppNotification(
      id: doc.id,
      type: _str(m['type']),
      fromUid: _str(m['fromUid']),
      fromUsername: _str(m['fromUsername']),
      fromPhotoUrl: _str(m['fromPhotoUrl']),
      postId: _str(m['postId']),
      postThumb: _str(m['postThumb']),
      text: _str(m['text']),
      read: m['read'] == true,
      createdAt: _date(m['createdAt']),
    );
  }
}
