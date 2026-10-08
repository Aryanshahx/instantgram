import 'package:cloud_firestore/cloud_firestore.dart';

import 'music.dart';
import 'story.dart';

/// A highlight on a profile: a named set of moments that stays after they expire.
/// `users/{uid}/highlights/{id}` = {title, cover, items: [...], at}.
class Highlight {
  const Highlight({
    required this.id,
    required this.title,
    this.items = const [],
    this.coverRef = '',
    this.at,
  });

  final String id;
  final String title;
  final List<HighlightItem> items;

  /// The picture on the circle ('' = the newest item's cover).
  final String coverRef;
  final DateTime? at;

  static const int maxItems = 100;
  static const int maxHighlights = 30;

  String get cover {
    if (coverRef.isNotEmpty) return coverRef;
    return items.isEmpty ? '' : items.last.coverRef;
  }

  Highlight copyWith({
    String? title,
    List<HighlightItem>? items,
    String? coverRef,
  }) => Highlight(
    id: id,
    title: title ?? this.title,
    items: items ?? this.items,
    coverRef: coverRef ?? this.coverRef,
    at: at,
  );

  /// Trimmed, at most 20 characters, never empty.
  static String cleanTitle(String s) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.isEmpty) return 'Highlights';
    return t.length > 20 ? t.substring(0, 20) : t;
  }

  Map<String, dynamic> toMap() => {
    'title': cleanTitle(title),
    'cover': coverRef,
    'items': [for (final i in items.take(maxItems)) i.toMap()],
  };

  factory Highlight.fromMap(String id, Map<String, dynamic> m) {
    final raw = m['items'];
    final at = m['at'];
    return Highlight(
      id: id,
      title: m['title'] is String
          ? cleanTitle(m['title'] as String)
          : 'Highlights',
      coverRef: m['cover'] is String ? m['cover'] as String : '',
      items: raw is List
          ? [for (final e in raw) ?HighlightItem.fromMap(e)]
          : const [],
      at: at is Timestamp ? at.toDate() : null,
    );
  }

  /// The highlight as one person's moments, to play in the moments viewer.
  StoryGroup toGroup(String ownerId, String username, String photoUrl) =>
      StoryGroup(
        authorId: ownerId,
        username: username,
        photoUrl: photoUrl,
        stories: [
          for (final i in items) i.toStory(ownerId, username, photoUrl),
        ],
      );

  /// Every stored file this highlight uses.
  Set<String> get refs => {for (final i in items) ...i.refs};
}

/// One moment inside a highlight (a copy of its fields, so it lives on after it expires).
class HighlightItem {
  const HighlightItem({
    required this.id,
    this.imageRef = '',
    this.videoRef = '',
    this.thumbRef = '',
    this.duration = 0,
    this.overlays = const [],
    this.musicId = '',
    this.musicVolume = 0.8,
    this.keepSound = true,
    required this.createdAt,
    this.storyId = '',
    this.own = false,
  });

  final String id;
  final String imageRef;
  final String videoRef;
  final String thumbRef;
  final int duration;
  final List<StoryOverlay> overlays;
  final String musicId;
  final double musicVolume;
  final bool keepSound;
  final DateTime createdAt;

  /// The moment it came from ('' = shared only to the highlight).
  final String storyId;

  /// Its files belong only to the highlight (removed together with it).
  final bool own;

  bool get isVideo => videoRef.isNotEmpty;
  String get coverRef => isVideo ? thumbRef : imageRef;
  Set<String> get refs => {
    for (final r in [imageRef, videoRef, thumbRef, deviceMusicRef(musicId)])
      if (r.isNotEmpty) r,
  };

  factory HighlightItem.fromStory(Story s, {required String id}) =>
      HighlightItem(
        id: id,
        imageRef: s.imageRef,
        videoRef: s.videoRef,
        thumbRef: s.thumbRef,
        duration: s.duration,
        overlays: s.overlays,
        musicId: s.musicId,
        musicVolume: s.musicVolume,
        keepSound: s.keepSound,
        createdAt: s.createdAt,
        storyId: s.id,
      );

  Story toStory(String ownerId, String username, String photoUrl) => Story(
    id: id,
    authorId: ownerId,
    username: username,
    photoUrl: photoUrl,
    imageRef: imageRef,
    createdAt: createdAt,
    videoRef: videoRef,
    thumbRef: thumbRef,
    duration: duration,
    overlays: overlays,
    musicId: musicId,
    musicVolume: musicVolume,
    keepSound: keepSound,
    // files of a copied moment may still be used by the moment itself
    shared: !own,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    if (imageRef.isNotEmpty) 'i': imageRef,
    if (videoRef.isNotEmpty) 'v': videoRef,
    if (thumbRef.isNotEmpty) 'th': thumbRef,
    if (duration > 0) 'd': duration,
    if (overlays.isNotEmpty)
      'o': [for (final o in overlays.take(20)) o.toMap()],
    if (musicId.isNotEmpty) 'm': musicId,
    if (musicId.isNotEmpty) 'mv': musicVolume,
    if (!keepSound) 'ks': false,
    'at': Timestamp.fromDate(createdAt),
    if (storyId.isNotEmpty) 'sid': storyId,
    if (own) 'own': true,
  };

  static HighlightItem? fromMap(Object? v) {
    if (v is! Map) return null;
    String s(Object? x) => x is String ? x : '';
    final id = s(v['id']);
    final image = s(v['i']);
    final video = s(v['v']);
    if (id.isEmpty || (image.isEmpty && video.isEmpty)) return null;
    final o = v['o'];
    final at = v['at'];
    return HighlightItem(
      id: id,
      imageRef: image,
      videoRef: video,
      thumbRef: s(v['th']),
      duration: v['d'] is num ? (v['d'] as num).toInt() : 0,
      overlays: o is List
          ? [for (final e in o) ?StoryOverlay.fromMap(e)]
          : const [],
      musicId: s(v['m']),
      musicVolume: v['mv'] is num
          ? (v['mv'] as num).toDouble().clamp(0.0, 1.0)
          : 0.8,
      keepSound: v['ks'] != false,
      createdAt: at is Timestamp ? at.toDate() : DateTime.now(),
      storyId: s(v['sid']),
      own: v['own'] == true,
    );
  }
}
