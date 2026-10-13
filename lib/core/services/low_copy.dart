import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';

/// Makes the small "low" copy of a video (about 2 Mbps, smaller size).
/// The full video is always kept; players switch to the low copy only
/// while the network is too slow (no buffering).
class LowCopy {
  LowCopy._();

  /// Tests switch this off (no native compressor).
  static bool disabled = false;

  /// Smaller videos play fine anyway.
  static int minSourceBytes = 4 * 1024 * 1024;

  /// Give up after this long (the post is not held back forever).
  static Duration timeout = const Duration(minutes: 2);

  static Future<void> _queue = Future<void>.value();

  /// The low copy of [video], or null (too small, failed, not smaller).
  /// Calls run one after another (one hardware encoder).
  static Future<File?> make(File video) {
    if (disabled || kIsWeb || !Platform.isAndroid && !Platform.isIOS) {
      return Future.value(null);
    }
    final c = Completer<File?>();
    _queue = _queue.then((_) async {
      try {
        c.complete(await _make(video));
      } catch (e) {
        debugPrint('low copy: $e');
        c.complete(null);
      }
    });
    return c.future;
  }

  static Future<File?> _make(File video) async {
    final size = await video.length();
    if (size < minSourceBytes) return null;
    final lc = LightCompressor();
    final result = await lc
        .compressVideo(
          path: video.path,
          videoQuality: VideoQuality.low,
          isMinBitrateCheckEnabled: true, // skips videos under ~2 Mbps
          android: AndroidConfig(isSharedStorage: false),
          ios: IOSConfig(saveInGallery: false),
          video: Video(
            videoName: 'low_${DateTime.now().microsecondsSinceEpoch}.mp4',
            videoBitrateInMbps: 2,
          ),
        )
        .timeout(
          timeout,
          onTimeout: () {
            lc.cancelCompression();
            return const OnCancelled(isCancelled: true);
          },
        );
    if (result is! OnSuccess) return null;
    final out = File(result.destinationPath);
    if (!await out.exists()) return null;
    // only worth it when clearly smaller
    if (await out.length() > size * 0.7) {
      unawaited(out.delete().then((_) {}, onError: (Object _) {}));
      return null;
    }
    return out;
  }
}
