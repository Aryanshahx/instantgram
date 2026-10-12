import 'package:cloud_firestore/cloud_firestore.dart';

DateTime _date(Object? v) =>
    v is Timestamp ? v.toDate() : DateTime.now();
int _int(Object? v) => v is num ? v.toInt() : 0;
String _str(Object? v) => v is String ? v : '';

List<double>? _matrix(Object? v) {
  if (v is! List || v.length != 20) return null;
  final out = <double>[];
  for (final x in v) {
    if (x is! num) return null;
    out.add(x.toDouble());
  }
  return out;
}

bool _bool(Object? v) => v == true;

/// Who can see a post / clip / moment.
class Audience {
  Audience._();
  static const String everyone = 'everyone';
  static const String followers = 'followers';
  static const String onlyMe = 'only_me';

  static const List<String> all = [everyone, followers, onlyMe];

  static String label(String a) => switch (a) {
        followers => 'Followers',
        onlyMe => 'Only me',
        _ => 'Everyone',
      };

  static String normalize(Object? v) =>
      v is String && all.contains(v) ? v : everyone;
}

/// Edits for a video that are applied while playing
/// (the original file is uploaded unchanged).
class VideoEdits {
  const VideoEdits({
    this.trimStartMs = 0,
    this.trimEndMs = 0,
    this.filter,
    this.muted = false,
  });

  /// 0 = from the start.
  final int trimStartMs;

  /// 0 = to the end.
  final int trimEndMs;

  /// 4x5 color matrix (20 numbers) or null.
  final List<double>? filter;

  /// Original sound off.
  final bool muted;

  bool get hasTrim => trimStartMs > 0 || trimEndMs > 0;

  Map<String, dynamic> toMap() => {
        if (trimStartMs > 0) 'trimStartMs': trimStartMs,
        if (trimEndMs > 0) 'trimEndMs': trimEndMs,
        if (filter != null) 'filter': filter,
        if (muted) 'muteAudio': true,
      };

  factory VideoEdits.fromMap(Map<String, dynamic> m) => VideoEdits(
        trimStartMs: _int(m['trimStartMs']),
        trimEndMs: _int(m['trimEndMs']),
        filter: _matrix(m['filter']),
        muted: _bool(m['muteAudio']),
      );
}

/// One photo of a (multi-photo) post.
class MediaItem {
  const MediaItem({required this.url, this.key = '', this.aspectRatio = 1});
  final String url;
  final String key;
  final double aspectRatio;

  Map<String, dynamic> toMap() =>
      {'url': url, 'key': key, 'aspectRatio': aspectRatio};

  static MediaItem? fromMap(Object? v) {
    if (v is! Map) return null;
    final url = v['url'];
    if (url is! String || url.isEmpty) return null;
    final ar = v['aspectRatio'];
    return MediaItem(
      url: url,
      key: v['key'] is String ? v['key'] as String : '',
      aspectRatio: ar is num && ar > 0 ? ar.toDouble() : 1,
    );
  }
}

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
    this.media = const [],
    this.thumbUrl = '',
    this.thumbKey = '',
    this.edits = const VideoEdits(),
    this.audience = Audience.everyone,
    this.sharesCount = 0,
    this.hideLikes = false,
    this.hideComments = false,
    this.hideReposts = false,
    this.hideShares = false,
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

  /// All photos of a photo post (at least the cover).
  final List<MediaItem> media;

  /// Clip cover image ('' = none).
  final String thumbUrl;
  final String thumbKey;

  /// Clip trim / filter / mute.
  final VideoEdits edits;

  final String audience;
  final int sharesCount;
  final bool hideLikes;
  final bool hideComments;
  final bool hideReposts;
  final bool hideShares;

  bool get isClip => type == clip;
  bool get isMulti => !isClip && media.length > 1;

  /// Photos to show (falls back to the single mediaUrl).
  List<MediaItem> get photos => media.isNotEmpty
      ? media
      : [MediaItem(url: mediaUrl, key: mediaKey, aspectRatio: aspectRatio)];

  /// Every storage key used by this post (for delete).
  List<String> get allKeys => {
        if (mediaKey.isNotEmpty) mediaKey,
        for (final m in media)
          if (m.key.isNotEmpty) m.key,
        if (thumbKey.isNotEmpty) thumbKey,
      }.toList();

  factory Post.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      Post.fromMap(doc.id, doc.data() ?? const <String, dynamic>{});

  factory Post.fromMap(String id, Map<String, dynamic> m) {
    final ar = m['aspectRatio'];
    final media = m['media'] is List
        ? (m['media'] as List)
            .map(MediaItem.fromMap)
            .whereType<MediaItem>()
            .toList()
        : const <MediaItem>[];
    return Post(
      id: id,
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
      media: media,
      thumbUrl: _str(m['thumbUrl']),
      thumbKey: _str(m['thumbKey']),
      edits: VideoEdits.fromMap(m),
      audience: Audience.normalize(m['audience']),
      sharesCount: _int(m['sharesCount']),
      hideLikes: _bool(m['hideLikes']),
      hideComments: _bool(m['hideComments']),
      hideReposts: _bool(m['hideReposts']),
      hideShares: _bool(m['hideShares']),
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
    this.type = photo,
    this.durationMs = 0,
    this.edits = const VideoEdits(),
    this.audience = Audience.everyone,
  });

  static const String photo = 'photo';
  static const String video = 'video';

  final String id;
  final String authorId;
  final String authorUsername;
  final String authorPhotoUrl;
  final String mediaUrl;
  final String mediaKey;
  final DateTime createdAt;
  final String type;

  /// Video length after trim (0 = unknown).
  final int durationMs;
  final VideoEdits edits;
  final String audience;

  bool get isVideo => type == video;

  factory Story.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      Story.fromMap(doc.id, doc.data() ?? const <String, dynamic>{});

  factory Story.fromMap(String id, Map<String, dynamic> m) {
    return Story(
      id: id,
      authorId: _str(m['authorId']),
      authorUsername: _str(m['authorUsername']),
      authorPhotoUrl: _str(m['authorPhotoUrl']),
      mediaUrl: _str(m['mediaUrl']),
      mediaKey: _str(m['mediaKey']),
      createdAt: _date(m['createdAt']),
      type: _str(m['type']) == video ? video : photo,
      durationMs: _int(m['durationMs']),
      edits: VideoEdits.fromMap(m),
      audience: Audience.normalize(m['audience']),
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
