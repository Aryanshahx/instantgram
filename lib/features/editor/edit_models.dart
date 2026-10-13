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
  });

  String text;
  Color color;

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

  VideoEdits get videoEdits => VideoEdits(
    trimStartMs: trimStart,
    trimEndMs: trimEnd > 0 && trimEnd < durationMs ? trimEnd : 0,
    filter: color.matrixOrNull,
    muted: muted,
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
