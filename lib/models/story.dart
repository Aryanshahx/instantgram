import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/painting.dart';

import '../core/fonts.dart';
import '../core/media_url.dart';
import 'music.dart';

/// The longest video that can be put in a moment.
const int kMaxStorySeconds = 30;

/// How long a photo moment stays on screen.
const int kStoryPhotoSeconds = 6;

/// A text or emoji placed on a moment. Position and size are relative to the moment's
/// 9:16 picture, so it looks the same on every screen.
class StoryOverlay {
  const StoryOverlay({
    required this.text,
    this.dx = 0.5,
    this.dy = 0.5,
    this.scale = 1,
    this.color = 0xFFFFFFFF,
    this.pill = false,
    this.emoji = false,
    this.image = '',
    this.still = '',
    this.aspect = 1,
    this.from = 0,
    this.to = -1,
    this.font = '',
  });

  final String text;

  /// Text style id (lib/core/fonts.dart); '' = classic.
  final String font;

  /// Centre of the item: 0..1 across and down the picture.
  final double dx;
  final double dy;
  final double scale;

  /// ARGB colour of the text.
  final int color;

  /// Text sits on a rounded background.
  final bool pill;

  /// A sticker (large emoji) rather than text.
  final bool emoji;

  /// A picture sticker (Giphy): the animated link, a still frame for photos that are baked,
  /// and width / height.
  final String image;
  final String still;
  final double aspect;

  /// Videos: the seconds (in the video) in which it is shown. [to] below 0 = until the end.
  final double from;
  final double to;

  bool get isImage => image.isNotEmpty;

  /// Shown during the whole video.
  bool get isAlways => from <= 0 && to < 0;

  /// Is it on screen at [sec]?
  bool visibleAt(double sec) => sec >= from - 0.001 && (to < 0 || sec <= to);

  StoryOverlay copyWith({
    String? text,
    double? dx,
    double? dy,
    double? scale,
    int? color,
    bool? pill,
    double? from,
    double? to,
    String? font,
  }) => StoryOverlay(
    text: text ?? this.text,
    dx: dx ?? this.dx,
    dy: dy ?? this.dy,
    scale: scale ?? this.scale,
    color: color ?? this.color,
    pill: pill ?? this.pill,
    emoji: emoji,
    image: image,
    still: still,
    aspect: aspect,
    from: from ?? this.from,
    to: to ?? this.to,
    font: font ?? this.font,
  );

  /// Font size for a picture that is [canvasWidth] wide.
  double fontSize(double canvasWidth) =>
      canvasWidth * (isImage ? 0.36 : (emoji ? 0.2 : 0.075)) * scale;

  Color get textColor => Color(color);

  Map<String, dynamic> toMap() => {
    't': text.length > 200 ? text.substring(0, 200) : text,
    'x': double.parse(dx.toStringAsFixed(4)),
    'y': double.parse(dy.toStringAsFixed(4)),
    's': double.parse(scale.toStringAsFixed(3)),
    'c': color,
    'p': pill,
    'e': emoji,
    if (isImage) 'i': image,
    if (isImage && still.isNotEmpty) 'g': still,
    if (isImage) 'a': double.parse(aspect.toStringAsFixed(3)),
    if (from > 0) 'ts': double.parse(from.toStringAsFixed(2)),
    if (to >= 0) 'te': double.parse(to.toStringAsFixed(2)),
    if (font.isNotEmpty) 'f': font,
  };

  static StoryOverlay? fromMap(Object? v) {
    if (v is! Map) return null;
    final t = v['t'];
    if (t is! String || t.isEmpty) return null;
    final img = v['i'] is String ? v['i'] as String : '';
    final ok = img.startsWith('https://');
    double d(Object? x, double fallback) => x is num ? x.toDouble() : fallback;
    return StoryOverlay(
      text: t,
      dx: d(v['x'], 0.5).clamp(0.0, 1.0),
      dy: d(v['y'], 0.5).clamp(0.0, 1.0),
      scale: d(v['s'], 1).clamp(0.3, 6.0),
      color: v['c'] is num ? (v['c'] as num).toInt() : 0xFFFFFFFF,
      pill: v['p'] == true,
      emoji: v['e'] == true,
      image: ok ? img : '',
      still: ok && v['g'] is String ? v['g'] as String : '',
      aspect: d(v['a'], 1).clamp(0.2, 5.0),
      from: d(v['ts'], 0).clamp(0.0, 36000.0),
      to: v['te'] is num ? (v['te'] as num).toDouble().clamp(0.0, 36000.0) : -1,
      font: cleanFontId(v['f']),
    );
  }
}

class Story {
  const Story({
    required this.id,
    required this.authorId,
    required this.username,
    required this.photoUrl,
    required this.imageRef,
    required this.createdAt,
    this.videoRef = '',
    this.thumbRef = '',
    this.duration = 0,
    this.overlays = const [],
    this.musicId = '',
    this.musicVolume = 0.8,
    this.keepSound = true,
    this.shared = false,
    this.spotlight = false,
    this.limited = false,
    this.listName = '',
  });

  final String id;
  final String authorId;
  final String username;
  final String photoUrl;
  final String imageRef;
  final DateTime createdAt;

  /// Video moments: the file and its cover picture.
  final String videoRef;
  final String thumbRef;
  final int duration;

  final List<StoryOverlay> overlays;
  final String musicId;
  final double musicVolume;
  final bool keepSound;

  /// Made from a post: the files belong to the post, so deleting the moment keeps them.
  final bool shared;

  /// Shown first in followers' moments bar, with a glowing ring.
  final bool spotlight;

  /// Only for the people of one of the author's audience lists (stored in privateStories).
  final bool limited;

  /// The list's name (only the author sees it).
  final String listName;

  /// Where it is stored.
  String get collection => limited ? kPrivateStories : 'stories';

  bool get isVideo => videoRef.isNotEmpty;
  String get imageUrl => resolveMediaUrl(imageRef);
  String get videoUrl => resolveMediaUrl(videoRef);
  String get thumbUrl => resolveMediaUrl(thumbRef);

  /// The picture that stands for the moment (the photo, or the video's cover).
  String get coverUrl => isVideo ? thumbUrl : imageUrl;

  /// How long the moment is shown.
  int get seconds => isVideo
      ? (duration <= 0 ? kMaxStorySeconds : duration.clamp(1, kMaxStorySeconds))
      : kStoryPhotoSeconds;

  factory Story.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> d, {
    bool limited = false,
  }) {
    final m = d.data() ?? const <String, dynamic>{};
    String s(Object? v) => v is String ? v : '';
    final ts = m['createdAt'];
    final ov = m['overlays'];
    rememberMusic(s(m['musicId']), s(m['musicTitle']), s(m['musicArtist']));
    return Story(
      id: d.id,
      authorId: s(m['authorId']),
      username: s(m['authorUsername']),
      photoUrl: s(m['authorPhotoUrl']),
      imageRef: s(m['imageUrl']),
      createdAt: ts is Timestamp ? ts.toDate() : DateTime.now(),
      videoRef: s(m['videoUrl']),
      thumbRef: s(m['thumbnailUrl']),
      duration: m['duration'] is num ? (m['duration'] as num).toInt() : 0,
      overlays: ov is List
          ? [for (final e in ov) ?StoryOverlay.fromMap(e)]
          : const [],
      musicId: s(m['musicId']),
      musicVolume: m['musicVolume'] is num
          ? (m['musicVolume'] as num).toDouble().clamp(0.0, 1.0)
          : 0.8,
      keepSound: m['keepSound'] != false,
      shared: m['sharedFromPost'] == true,
      spotlight: m['spotlight'] == true,
      limited: limited,
      listName: limited ? s(m['listName']) : '',
    );
  }
}

class StoryGroup {
  StoryGroup({
    required this.authorId,
    required this.username,
    required this.photoUrl,
    required this.stories,
  });

  final String authorId;
  final String username;
  final String photoUrl;
  final List<Story> stories;

  /// One of the moments is in the spotlight: the group goes first, with a glowing ring.
  bool get spotlight => stories.any((s) => s.spotlight);
}

/// Moments for one audience list only.
const String kPrivateStories = 'privateStories';

/// Order of the moments bar: me first, then spotlights, then the newest.
int compareStoryGroups(StoryGroup a, StoryGroup b, String me) {
  if (a.authorId == me) return -1;
  if (b.authorId == me) return 1;
  if (a.spotlight != b.spotlight) return a.spotlight ? -1 : 1;
  return b.stories.last.createdAt.compareTo(a.stories.last.createdAt);
}
