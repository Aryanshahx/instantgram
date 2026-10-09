import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/media_url.dart';
import 'finish.dart';
import 'music.dart';

int _int(Object? v) => v is num ? v.toInt() : 0;
String _str(Object? v) => v is String ? v : '';

/// One photo or video of a post. A post with several of these is a carousel.
class PostItem {
  const PostItem({
    required this.video,
    required this.ref,
    this.thumbRef = '',
    this.width = 0,
    this.height = 0,
    this.seconds = 0,
    this.finish,
  });

  final bool video;

  /// `m:<key>` of the photo or video.
  final String ref;

  /// `m:<key>` of the video's cover ('' for photos).
  final String thumbRef;
  final int width;
  final int height;
  final int seconds;

  /// Texts, stickers and colour look shown over a video (null = none).
  final MediaFinish? finish;

  String get url => resolveMediaUrl(ref);
  String get thumbUrl => resolveMediaUrl(video ? thumbRef : ref);
  double get aspect => (width > 0 && height > 0) ? width / height : 0;

  Map<String, Object> toMap() => {
    't': video ? 'video' : 'image',
    'u': ref,
    if (thumbRef.isNotEmpty) 'th': thumbRef,
    if (width > 0 && height > 0) 'w': width,
    if (width > 0 && height > 0) 'h': height,
    if (seconds > 0) 'd': seconds,
    if (finish != null && !finish!.isEmpty) 'fin': finish!.toMap(),
  };

  static PostItem? fromMap(Object? e) {
    if (e is! Map) return null;
    final u = _str(e['u']);
    if (u.isEmpty) return null;
    return PostItem(
      video: e['t'] == 'video',
      ref: u,
      thumbRef: _str(e['th']),
      width: _int(e['w']),
      height: _int(e['h']),
      seconds: _int(e['d']),
      finish: MediaFinish.fromMap(e['fin']),
    );
  }
}

/// A photo clip always plays for this many seconds.
const int kPhotoClipSeconds = 5;

/// Most photos and videos one post can hold.
const int kMaxPostItems = 10;

/// Who may see a post, and which numbers are shown to others.
class PostOptions {
  const PostOptions({
    this.audience = kAudienceEveryone,
    this.hideLikes = false,
    this.hideComments = false,
    this.hideShares = false,
    this.profileOnly = false,
  });

  /// Shown on the author's profile only: not in Home, Clips, Explore or search.
  final bool profileOnly;

  /// [kAudienceEveryone], [kAudienceFollowers] or [kAudienceMe].
  final String audience;
  final bool hideLikes;
  final bool hideComments;
  final bool hideShares;

  Map<String, Object> toMap() => {
    'audience': audience,
    'hideLikes': hideLikes,
    'hideComments': hideComments,
    'hideShares': hideShares,
    'profileOnly': profileOnly,
    'shareCount': 0,
  };
}

const String kAudienceEveryone = 'everyone';
const String kAudienceFollowers = 'followers';
const String kAudienceMe = 'me';

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
    this.reportCount = 0,
    this.reportWeight = 0,
    this.sensitive = false,
    this.hidden = false,
    this.musicId = '',
    this.musicVolume = 0.8,
    this.musicStart = 0,
    this.keepSound = true,
    this.musicBaked = false,
    this.media = const [],
    this.shareCount = 0,
    this.repostCount = 0,
    this.pinned = false,
    this.finish,
    this.audience = kAudienceEveryone,
    this.hideLikes = false,
    this.hideComments = false,
    this.hideShares = false,
    this.authorPrivate = false,
    this.profileOnly = false,
    this.superCount = 0,
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

  /// People who reported it, and hidden by the admin panel.
  final int reportCount;
  final bool hidden;

  /// Reports weighted by how trusted each reporter is (normal = 2, new or flagged = 1,
  /// long-standing = 3). 0 on posts reported before v1.32.
  final int reportWeight;

  /// The phone's photo check found nudity: others see it blurred ("Tap to view").
  final bool sensitive;

  /// Reports as the auto-hide setting counts them (2 weight points = 1 report).
  double get effectiveReports =>
      reportWeight > 0 ? reportWeight / 2 : reportCount.toDouble();

  /// Music chosen from the app's own library ('' = none), its volume (0-1) and, for videos,
  /// whether the clip's own sound is kept underneath it.
  final String musicId;
  final double musicVolume;
  final bool keepSound;

  /// Seconds into the song where it starts (the part chosen in the editor).
  final double musicStart;

  /// The song is already mixed into the video file (made on the phone with a hit song). Then
  /// nothing is played on top of it; the name is still shown.
  final bool musicBaked;

  /// Times it was shared (link or sent to people).
  final int shareCount;

  /// People who reposted it to their profile.
  final int repostCount;

  /// The author pinned it to the top of their profile.
  final bool pinned;

  /// Texts, stickers and colour look shown over a single video post (null = none).
  final MediaFinish? finish;

  /// [kAudienceEveryone], [kAudienceFollowers] or [kAudienceMe].
  final String audience;

  /// The author chose to hide these numbers from other people (the author still sees them).
  final bool hideLikes;
  final bool hideComments;
  final bool hideShares;

  /// The author's account was private when this was posted.
  final bool authorPrivate;

  /// Only on the author's profile (see [PostOptions.profileOnly]).
  final bool profileOnly;

  /// Super hearts: one per person, on top of a like.
  final int superCount;

  /// The photos and videos of a carousel (empty for a normal one-photo or one-video post).
  final List<PostItem> media;

  /// Everything in the post, in order (a normal post has exactly one item).
  List<PostItem> get items {
    if (media.isNotEmpty) return media;
    return [
      if (isVideo)
        PostItem(
          video: true,
          ref: videoRef,
          thumbRef: thumbRef,
          width: videoWidth,
          height: videoHeight,
          seconds: videoDuration,
          finish: finish,
        )
      else
        PostItem(
          ref: imageRef,
          width: imageWidth,
          height: imageHeight,
          video: false,
        ),
    ];
  }

  /// Several photos / videos swiped sideways.
  bool get isCarousel => media.length > 1;

  bool get isVideo => type == 'video';

  /// A photo shown as a clip: the picture for [videoDuration] seconds with music.
  bool get isPhotoClip => type == 'photoclip';

  /// Appears in Clips (a video or a photo clip).
  bool get isClip => isVideo || isPhotoClip;

  bool get hasMusic => musicId.isNotEmpty;

  /// The track a player has to start next to this post (null when there is none, or when the
  /// song is part of the video file already).
  MusicTrack? get playableMusic => musicBaked ? null : musicById(musicId);

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
    rememberMusic(
      _str(m['musicId']),
      _str(m['musicTitle']),
      _str(m['musicArtist']),
    );
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
      reportCount: _int(m['reportCount']),
      reportWeight: _int(m['reportWeight']),
      sensitive: m['sensitive'] == true,
      hidden: m['hidden'] == true,
      musicId: _str(m['musicId']),
      musicVolume: m['musicVolume'] is num
          ? (m['musicVolume'] as num).toDouble().clamp(0.0, 1.0)
          : 0.8,
      musicStart: m['musicStart'] is num
          ? (m['musicStart'] as num).toDouble().clamp(0.0, 3600.0)
          : 0,
      keepSound: m['keepSound'] is bool ? m['keepSound'] as bool : true,
      musicBaked: m['musicBaked'] == true,
      shareCount: _int(m['shareCount']),
      repostCount: _int(m['repostCount']),
      pinned: m['pinned'] == true,
      finish: MediaFinish.fromMap(m['finish']),
      audience: _str(m['audience']).isEmpty
          ? kAudienceEveryone
          : _str(m['audience']),
      hideLikes: m['hideLikes'] == true,
      hideComments: m['hideComments'] == true,
      hideShares: m['hideShares'] == true,
      authorPrivate: m['authorPrivate'] == true,
      profileOnly: m['profileOnly'] == true,
      superCount: _int(m['superCount']),
      media: m['media'] is List
          ? [for (final e in m['media'] as List) ?PostItem.fromMap(e)]
          : const [],
    );
  }
}
