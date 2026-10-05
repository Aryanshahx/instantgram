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
    this.imageWidth = 0,
    this.imageHeight = 0,
    this.likeCount = 0,
    this.commentCount = 0,
    this.viewCount = 0,
    this.musicId = '',
    this.musicVolume = 0.8,
    this.keepSound = true,
  });

  final String id;
  final String authorId;
  final String authorUsername;
  final String authorPhotoUrl;

  /// 'image' or 'video'
  final String type;
  final String caption;
  final DateTime createdAt;

  /// Stored references (`m:<key>`), see core/media_url.dart.
  final String imageRef;
  final String videoRef;
  final String thumbRef;

  final int videoDuration;
  final int videoWidth;
  final int videoHeight;

  /// Proportions of a photo (only the ratio matters; 0 for photos from before v1.5).
  final int imageWidth;
  final int imageHeight;

  final int likeCount;
  final int commentCount;

  /// People who watched it (counted once per person).
  final int viewCount;

  /// Music chosen from the app's own library ('' = none), its volume (0-1) and, for videos,
  /// whether the clip's own sound is kept underneath it.
  final String musicId;
  final double musicVolume;
  final bool keepSound;

  bool get isVideo => type == 'video';

  /// A photo shown as a clip: the picture for [videoDuration] seconds with music.
  bool get isPhotoClip => type == 'photoclip';

  /// Appears in Clips (a video or a photo clip).
  bool get isClip => isVideo || isPhotoClip;

  bool get hasMusic => musicId.isNotEmpty;

  /// Posts that can no longer be shown: old "paste a link" videos, and anything that
  /// lived in the removed Telegram storage.
  bool get isLegacyLink =>
      isVideo ? !videoRef.startsWith('m:') : isRemovedStorageRef(imageRef);

  String get imageUrl => resolveMediaUrl(imageRef);
  String get videoUrl => resolveMediaUrl(videoRef);
  String get thumbnailUrl => resolveMediaUrl(thumbRef);

  /// width / height of the video (0 if unknown).
  double get videoAspect =>
      (videoWidth > 0 && videoHeight > 0) ? videoWidth / videoHeight : 0;

  /// width / height of the photo (0 if unknown).
  double get imageAspect =>
      (imageWidth > 0 && imageHeight > 0) ? imageWidth / imageHeight : 0;

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
      imageWidth: _int(m['imageWidth']),
      imageHeight: _int(m['imageHeight']),
      likeCount: _int(m['likeCount']),
      commentCount: _int(m['commentCount']),
      viewCount: _int(m['viewCount']),
      musicId: _str(m['musicId']),
      musicVolume: m['musicVolume'] is num
          ? (m['musicVolume'] as num).toDouble().clamp(0.0, 1.0)
          : 0.8,
      keepSound: m['keepSound'] is bool ? m['keepSound'] as bool : true,
    );
  }
}
