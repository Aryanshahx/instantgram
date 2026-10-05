import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/painting.dart';

import '../core/media_url.dart';

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
  });

  final String text;

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

  StoryOverlay copyWith({
    String? text,
    double? dx,
    double? dy,
    double? scale,
    int? color,
    bool? pill,
  }) => StoryOverlay(
    text: text ?? this.text,
    dx: dx ?? this.dx,
    dy: dy ?? this.dy,
    scale: scale ?? this.scale,
    color: color ?? this.color,
    pill: pill ?? this.pill,
    emoji: emoji,
  );

  /// Font size for a picture that is [canvasWidth] wide.
  double fontSize(double canvasWidth) =>
      canvasWidth * (emoji ? 0.2 : 0.075) * scale;

  Color get textColor => Color(color);

  Map<String, dynamic> toMap() => {
    't': text.length > 200 ? text.substring(0, 200) : text,
    'x': double.parse(dx.toStringAsFixed(4)),
    'y': double.parse(dy.toStringAsFixed(4)),
    's': double.parse(scale.toStringAsFixed(3)),
    'c': color,
    'p': pill,
    'e': emoji,
  };

  static StoryOverlay? fromMap(Object? v) {
    if (v is! Map) return null;
    final t = v['t'];
    if (t is! String || t.isEmpty) return null;
    double d(Object? x, double fallback) => x is num ? x.toDouble() : fallback;
    return StoryOverlay(
      text: t,
      dx: d(v['x'], 0.5).clamp(0.0, 1.0),
      dy: d(v['y'], 0.5).clamp(0.0, 1.0),
      scale: d(v['s'], 1).clamp(0.3, 6.0),
      color: v['c'] is num ? (v['c'] as num).toInt() : 0xFFFFFFFF,
      pill: v['p'] == true,
      emoji: v['e'] == true,
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

  factory Story.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const <String, dynamic>{};
    String s(Object? v) => v is String ? v : '';
    final ts = m['createdAt'];
    final ov = m['overlays'];
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
          ? [
              for (final e in ov)
                ?StoryOverlay.fromMap(e),
            ]
          : const [],
      musicId: s(m['musicId']),
      musicVolume: m['musicVolume'] is num
          ? (m['musicVolume'] as num).toDouble().clamp(0.0, 1.0)
          : 0.8,
      keepSound: m['keepSound'] != false,
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
}
