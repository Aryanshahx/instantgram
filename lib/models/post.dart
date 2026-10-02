import 'package:cloud_firestore/cloud_firestore.dart';

import 'video_link.dart';

int _int(Object? v) => v is num ? v.toInt() : 0;
String _str(Object? v) => v is String ? v : '';

class Post {
  const Post({
    required this.id,
    required this.authorId,
    required this.authorUsername,
    required this.authorPhotoUrl,
    required this.type,
    required this.caption,
    required this.createdAt,
    this.imageUrl = '',
    this.imagePath = '',
    this.videoUrl = '',
    this.videoPlatform,
    this.videoId,
    this.thumbnailUrl = '',
    this.likeCount = 0,
    this.commentCount = 0,
  });

  final String id;
  final String authorId;
  final String authorUsername;
  final String authorPhotoUrl;

  /// 'image' or 'video'
  final String type;
  final String caption;
  final DateTime createdAt;

  final String imageUrl;
  final String imagePath;

  final String videoUrl;
  final VideoPlatform? videoPlatform;
  final String? videoId;
  final String thumbnailUrl;

  final int likeCount;
  final int commentCount;

  bool get isVideo => type == 'video';

  factory Post.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const <String, dynamic>{};
    final ts = m['createdAt'];
    final vid = _str(m['videoId']);
    return Post(
      id: d.id,
      authorId: _str(m['authorId']),
      authorUsername: _str(m['authorUsername']),
      authorPhotoUrl: _str(m['authorPhotoUrl']),
      type: _str(m['type']).isEmpty ? 'image' : _str(m['type']),
      caption: _str(m['caption']),
      createdAt: ts is Timestamp ? ts.toDate() : DateTime.now(),
      imageUrl: _str(m['imageUrl']),
      imagePath: _str(m['imagePath']),
      videoUrl: _str(m['videoUrl']),
      videoPlatform: VideoPlatformX.fromName(m['videoPlatform'] as String?),
      videoId: vid.isEmpty ? null : vid,
      thumbnailUrl: _str(m['thumbnailUrl']),
      likeCount: _int(m['likeCount']),
      commentCount: _int(m['commentCount']),
    );
  }
}
