import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/services/media_service.dart';
import '../../shared/models/post.dart';
import 'filters.dart';

/// What the user is creating.
enum ComposeMode { photo, clip, story }

/// Longest allowed video per mode.
int maxVideoMs(ComposeMode mode) =>
    mode == ComposeMode.story ? 60 * 1000 : 90 * 1000;

/// Crop shapes.
enum CropAspect {
  original('Original', null),
  square('1:1', 1),
  portrait('4:5', 4 / 5),
  landscape('16:9', 16 / 9),
  story('9:16', 9 / 16);

  const CropAspect(this.label, this.ratio);
  final String label;
  final double? ratio;
}

List<CropAspect> aspectsFor(ComposeMode mode) => mode == ComposeMode.story
    ? const [
        CropAspect.story,
        CropAspect.original,
        CropAspect.portrait,
        CropAspect.square,
      ]
    : const [
        CropAspect.original,
        CropAspect.square,
        CropAspect.portrait,
        CropAspect.landscape,
      ];

/// Text placed on a photo.
class TextLayer {
  TextLayer({
    required this.text,
    this.color = Colors.white,
    this.size = 0.08,
    this.pos = const Offset(0.5, 0.5),
    this.background = false,
    this.sticker = false,
  });

  String text;
  Color color;

  /// v0.12: an emoji sticker (no shadow, bigger).
  final bool sticker;

  /// Font size as a part of the frame width.
  double size;

  /// Center position (0..1 of the frame).
  Offset pos;
  bool background;
}

/// One picked photo/video and all its edits.
class EditItem {
  EditItem(this.src, {required ComposeMode mode})
    : aspect = mode == ComposeMode.story
          ? CropAspect.story
          : CropAspect.original;

  final PickedMedia src;
  File get file => src.file;
  bool get isVideo => src.isVideo;

  /// Crop frame + photo box as last shown on screen (for the export).
  Size? frameSize;
  Size? photoSize;

  // ---- photo + video
  ColorEdits color = const ColorEdits();

  // ---- photo
  int turns = 0;
  bool flip = false;
  CropAspect aspect;
  final List<TextLayer> texts = [];

  /// Pixel size of the photo (null until loaded).
  Size? natural;

  /// Zoom / move inside the crop frame (null = centered).
  TransformationController? zoom;
  bool zoomChanged = false;

  void resetZoom() {
    zoom?.dispose();
    zoom = null;
    zoomChanged = false;
  }

  bool get photoEdited =>
      !color.isNone ||
      turns % 4 != 0 ||
      flip ||
      aspect != CropAspect.original ||
      zoomChanged ||
      texts.isNotEmpty;

  // ---- video
  int durationMs = 0;
  int trimStart = 0;
  int trimEnd = 0;
  bool muted = false;
  double videoAspect = 9 / 16;
  List<dynamic>? thumbs; // Uint8List? per slot

  int get trimmedMs =>
      ((trimEnd > 0 ? trimEnd : durationMs) - trimStart).clamp(0, 1 << 30);

  /// End of the trim (ms in the file).
  int get endMs => trimEnd > 0 ? trimEnd : durationMs;

  // ---- v0.12: split, texts / stickers, voice over
  /// Split points (ms in the file).
  final List<int> splits = [];

  /// Removed parts.
  List<VideoCut> cuts = [];
  final List<VideoOverlay> overlays = [];
  String voicePath = '';
  int voiceStartMs = 0; // in the PLAYED video
  int voiceDurMs = 0;

  bool get hasVoice => voicePath.isNotEmpty && voiceDurMs > 0;

  /// Cuts inside the trim only.
  List<VideoCut> get activeCuts => VideoTime.normalize([
    for (final c in cuts)
      if (c.endMs > trimStart && c.startMs < endMs)
        VideoCut(
          c.startMs < trimStart ? trimStart : c.startMs,
          c.endMs > endMs ? endMs : c.endMs,
        ),
  ]);

  /// Length after trim and removed parts.
  int get playedMs => VideoTime.playedMs(trimStart, endMs, activeCuts);

  /// Parts between split points (inside the trim).
  List<VideoCut> get segments {
    final pts = <int>[
      trimStart,
      ...(splits.where((x) => x > trimStart && x < endMs).toList()..sort()),
      endMs,
    ];
    return [
      for (var i = 0; i + 1 < pts.length; i++)
        if (pts[i + 1] > pts[i]) VideoCut(pts[i], pts[i + 1]),
    ];
  }

  /// Part under [ms] (null = outside the trim).
  VideoCut? segmentAt(int ms) {
    for (final s in segments) {
      if (ms >= s.startMs && ms < s.endMs) return s;
    }
    final seg = segments;
    if (seg.isNotEmpty && ms == seg.last.endMs) return seg.last;
    return null;
  }

  bool isCut(VideoCut seg) =>
      activeCuts.any((c) => c.startMs <= seg.startMs && c.endMs >= seg.endMs);

  // ---- v0.14: every part has its own trim (= removed bits at its ends)

  /// Shortest part you can keep.
  static const int minPartMs = 300;

  /// The kept piece of [seg] (null = the whole part is deleted).
  VideoCut? keptOf(VideoCut seg) {
    final cs = activeCuts;
    var a = seg.startMs, b = seg.endMs;
    var moved = true;
    while (moved) {
      moved = false;
      for (final c in cs) {
        if (c.startMs <= a && c.endMs > a) {
          a = c.endMs < b ? c.endMs : b;
          moved = true;
        }
        if (c.startMs < b && c.endMs >= b) {
          b = c.startMs > a ? c.startMs : a;
          moved = true;
        }
      }
      if (a >= b) return null;
    }
    return VideoCut(a, b);
  }

  /// [cuts] without anything inside [seg].
  List<VideoCut> _cutsOutside(VideoCut seg) {
    final out = <VideoCut>[];
    for (final c in cuts) {
      if (c.endMs <= seg.startMs || c.startMs >= seg.endMs) {
        out.add(c);
        continue;
      }
      if (c.startMs < seg.startMs) out.add(VideoCut(c.startMs, seg.startMs));
      if (c.endMs > seg.endMs) out.add(VideoCut(seg.endMs, c.endMs));
    }
    return out;
  }

  /// Keep only [keepStart]..[keepEnd] of the part [seg].
  void setKept(VideoCut seg, int keepStart, int keepEnd) {
    if (seg.length <= minPartMs) return;
    final a = keepStart.clamp(seg.startMs, seg.endMs - minPartMs);
    final b = keepEnd.clamp(a + minPartMs, seg.endMs);
    cuts = VideoTime.normalize([
      ..._cutsOutside(seg),
      if (a > seg.startMs) VideoCut(seg.startMs, a),
      if (b < seg.endMs) VideoCut(b, seg.endMs),
    ]);
  }

  /// Bring back the whole part [seg] (no trim, not deleted).
  void restorePart(VideoCut seg) =>
      cuts = VideoTime.normalize(_cutsOutside(seg));

  /// Split at [ms]. Returns a reason when it can't (null = done).
  String? splitAt(int ms) {
    final seg = segmentAt(ms);
    if (seg == null) return 'Move the white line inside the video.';
    final kept = keptOf(seg);
    if (kept == null) return 'This part is deleted. Bring it back first.';
    if (ms <= kept.startMs + minPartMs || ms >= kept.endMs - minPartMs) {
      return 'Too close to the end of a part. Move the white line a bit.';
    }
    if (splits.any((x) => (x - ms).abs() < minPartMs)) {
      return 'There is already a split here.';
    }
    splits
      ..add(ms)
      ..sort();
    return null;
  }

  /// Index of the part under [ms] (-1 = none).
  int segmentIndexAt(int ms) {
    final seg = segmentAt(ms);
    if (seg == null) return -1;
    return segments.indexWhere((s) => s.startMs == seg.startMs);
  }

  VideoEdits get videoEdits => VideoEdits(
    trimStartMs: trimStart,
    trimEndMs: trimEnd > 0 && trimEnd < durationMs ? trimEnd : 0,
    filter: color.matrixOrNull,
    muted: muted,
    cuts: activeCuts,
    overlays: List.unmodifiable(overlays),
    voicePath: hasVoice ? voicePath : '',
    voiceStartMs: hasVoice ? voiceStartMs : 0,
    voiceDurMs: hasVoice ? voiceDurMs : 0,
  );
}

/// Result of the editor (ready to share).
class EditedMedia {
  const EditedMedia({
    required this.file,
    required this.isVideo,
    required this.aspectRatio,
    this.edits = const VideoEdits(),
    this.durationMs = 0,
    this.preview,
  });

  final File file;
  final bool isVideo;
  final double aspectRatio;
  final VideoEdits edits;
  final int durationMs;

  /// For videos: first frame (if it could be made).
  final File? preview;
}
