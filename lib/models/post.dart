import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/media_url.dart';

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
    this.imageRef = '',
    this.videoRef = '',
    this.thumbRef = '',
    this.videoDuration = 0,
    this.videoWidth = 0,
    this.videoHeight = 0,
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

  /// Stored references (`tg:<handle>`), see core/media_url.dart.
  final String imageRef;
  final String videoRef;
  final String thumbRef;

  final int videoDuration;
  final int videoWidth;
  final int videoHeight;

  final int likeCount;
  final int commentCount;

  bool get isVideo => type == 'video';

  /// Posts made by the old "paste a link" feature have no playable file.
  bool get isLegacyLink => isVideo && !videoRef.startsWith('tg:');

  String get imageUrl => resolveMediaUrl(imageRef);
  String get videoUrl => resolveMediaUrl(videoRef);
  String get thumbnailUrl => resolveMediaUrl(thumbRef);

  /// width / height of the video (0 if unknown).
  double get videoAspect =>
      (videoWidth > 0 && videoHeight > 0) ? videoWidth / videoHeight : 0;

  factory Post.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const <String, dynamic>{};
    final ts = m['createdAt'];
    return Post(
      id: d.id,
      authorId: _str(m['authorId']),
      authorUsername: _str(m['authorUsername']),
      authorPhotoUrl: _str(m['authorPhotoUrl']),
      type: _str(m['type']).isEmpty ? 'image' : _str(m['type']),
      caption: _str(m['caption']),
      createdAt: ts is Timestamp ? ts.toDate() : DateTime.now(),
      imageRef: _str(m['imageUrl']),
      videoRef: _str(m['videoUrl']),
      thumbRef: _str(m['thumbnailUrl']),
      videoDuration: _int(m['videoDuration']),
      videoWidth: _int(m['videoWidth']),
      videoHeight: _int(m['videoHeight']),
      likeCount: _int(m['likeCount']),
      commentCount: _int(m['commentCount']),
    );
  }
}
