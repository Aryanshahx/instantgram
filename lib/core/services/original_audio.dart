import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../shared/models/post.dart';

/// "Original audio": the sound of your own video becomes a song page, so
/// others can tap it under your name and make a clip with the same sound.
///
/// The phone copies the video's sound (AAC) into a small .m4a file - no
/// re-encoding, only the played part (trim + removed parts).
class OriginalAudio {
  OriginalAudio._();

  static const MethodChannel _ch = MethodChannel('instantgram/vision');

  /// Tests replace the phone part.
  static Future<({String path, int durationMs})?> Function(
    String path,
    VideoEdits edits,
  )?
  debugExtract;

  /// Tests: act like an Android phone (the phone part is mocked).
  @visibleForTesting
  static bool debugAndroid = false;

  /// Should this video's own sound get a page? Not when music was added,
  /// the sound is off, or it is a moment.
  static bool wanted({
    required bool isMoment,
    required bool hasMusic,
    required bool isVideo,
    required bool muted,
  }) => !isMoment && !hasMusic && isVideo && !muted;

  /// The played part of [path] as an .m4a file, or null (no sound / not
  /// AAC / not Android / failed).
  static Future<({String path, int durationMs})?> extract(
    String path,
    VideoEdits edits,
  ) async {
    final hook = debugExtract;
    if (hook != null) return hook(path, edits);
    if (kIsWeb || !(debugAndroid || Platform.isAndroid)) return null;
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('extractAudio', {
        'path': path,
        'startMs': edits.trimStartMs,
        'endMs': edits.trimEndMs,
        'cuts': [
          for (final c in edits.cuts) ...[c.startMs, c.endMs],
        ],
      });
      final out = r?['path'];
      if (out is! String || out.isEmpty) return null;
      final ms = (r?['durationMs'] as num?)?.toInt() ?? 0;
      if (ms < 1000) return null; // under a second: not worth a page
      return (path: out, durationMs: ms);
    } catch (e) {
      debugPrint('original audio: $e');
      return null;
    }
  }
}
