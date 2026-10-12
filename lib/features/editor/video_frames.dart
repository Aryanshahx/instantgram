import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_video_thumbnail_plus/flutter_video_thumbnail_plus.dart';

/// Grabs still frames from a local video (null if the phone can't).
class VideoFrames {
  VideoFrames._();

  static Future<Uint8List?> bytes(
    String path,
    int timeMs, {
    int maxHeight = 120,
    int quality = 60,
  }) async {
    try {
      return await FlutterVideoThumbnailPlus.thumbnailData(
        video: path,
        imageFormat: ImageFormat.jpeg,
        maxHeight: maxHeight,
        timeMs: timeMs,
        quality: quality,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<File?> file(
    String path,
    int timeMs, {
    int maxWidth = 1080,
    int quality = 88,
  }) async {
    try {
      final dir = await Directory.systemTemp.createTemp('ig_cover');
      final out = await FlutterVideoThumbnailPlus.thumbnailFile(
        video: path,
        thumbnailPath: '${dir.path}/cover_$timeMs.jpg',
        imageFormat: ImageFormat.jpeg,
        maxWidth: maxWidth,
        timeMs: timeMs,
        quality: quality,
      );
      if (out == null) return null;
      final f = File(out);
      return await f.exists() ? f : null;
    } catch (_) {
      return null;
    }
  }
}
