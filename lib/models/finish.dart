import 'package:flutter/painting.dart';

import '../services/photo_edit.dart';
import 'story.dart';

/// Colour changes of a video (filter, brightness, contrast, saturation). They are not baked
/// into the file: they are applied while the clip plays, so the video stays untouched.
class VideoLook {
  const VideoLook({
    this.filter = 0,
    this.brightness = 0,
    this.contrast = 1,
    this.saturation = 1,
  });

  /// Index in [kPhotoFilters].
  final int filter;
  final double brightness;
  final double contrast;
  final double saturation;

  bool get isEmpty =>
      filter == 0 &&
      brightness.abs() < 0.001 &&
      (contrast - 1).abs() < 0.001 &&
      (saturation - 1).abs() < 0.001;

  /// The 4x5 colour matrix (same maths as the photo editor).
  List<double> get matrix => PhotoEdits(
    filter: filter,
    brightness: brightness,
    contrast: contrast,
    saturation: saturation,
  ).colorMatrix;

  Map<String, Object> toMap() => {
    'f': filter,
    'b': double.parse(brightness.toStringAsFixed(3)),
    'c': double.parse(contrast.toStringAsFixed(3)),
    's': double.parse(saturation.toStringAsFixed(3)),
  };

  static VideoLook? fromMap(Object? v) {
    if (v is! Map) return null;
    double d(Object? x, double fallback) => x is num ? x.toDouble() : fallback;
    final f = v['f'] is num ? (v['f'] as num).toInt() : 0;
    final look = VideoLook(
      filter: f.clamp(0, kPhotoFilters.length - 1),
      brightness: d(v['b'], 0).clamp(-1.0, 1.0),
      contrast: d(v['c'], 1).clamp(0.5, 1.5),
      saturation: d(v['s'], 1).clamp(0.0, 2.0),
    );
    return look.isEmpty ? null : look;
  }
}

/// What is shown on top of a video when people watch it: texts, stickers and the colour look.
class MediaFinish {
  const MediaFinish({this.overlays = const [], this.look});

  static const MediaFinish none = MediaFinish();

  final List<StoryOverlay> overlays;
  final VideoLook? look;

  bool get isEmpty => overlays.isEmpty && (look == null || look!.isEmpty);

  Map<String, Object> toMap() => {
    if (overlays.isNotEmpty) 'ov': [for (final o in overlays) o.toMap()],
    if (look != null && !look!.isEmpty) 'lk': look!.toMap(),
  };

  static MediaFinish? fromMap(Object? v) {
    if (v is! Map) return null;
    final ov = v['ov'] is List
        ? [for (final e in v['ov'] as List) ?StoryOverlay.fromMap(e)]
        : const <StoryOverlay>[];
    final f = MediaFinish(overlays: ov, look: VideoLook.fromMap(v['lk']));
    return f.isEmpty ? null : f;
  }
}

/// Matrix as a Flutter colour filter.
ColorFilter lookFilter(VideoLook look) => ColorFilter.matrix(look.matrix);
