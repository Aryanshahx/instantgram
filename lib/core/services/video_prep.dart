import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart';
import 'package:path_provider/path_provider.dart';

import 'mp4_faststart.dart';

/// What to do with a video before upload.
@immutable
class HdPlan {
  const HdPlan({
    required this.compress,
    this.width = 0,
    this.height = 0,
    this.keepSize = false,
    this.fps,
    this.mbps = VideoPrep.hdMbps,
  });

  /// False = upload the file as it is (already small HD).
  final bool compress;

  /// New size (encoded orientation, even numbers). 0 with [keepSize].
  final int width;
  final int height;
  final bool keepSize;

  /// Lower frame rate (60 fps -> 30), or null.
  final int? fps;

  /// Video bitrate (never more than the original had).
  final int mbps;

  @override
  String toString() =>
      'HdPlan(compress: $compress, ${keepSize ? 'same size' : '${width}x$height'}, fps: $fps, $mbps Mbps)';
}

/// Prepares videos on the phone before upload (v0.8):
///  * HD: max 1080p, max 30 fps, about 6 Mbps. Looks the same on a phone,
///    but the file is 3-6x smaller -> upload and playback much faster
///  * low copy: 540p, about 1 Mbps (played only when the network is slow)
///  * "fast start": the video index goes to the front of the file, so
///    players start after the first few hundred KB
class VideoPrep {
  VideoPrep._();

  /// Tests switch this off (no native compressor).
  static bool disabled = false;

  static const int hdShortSide = 1080;
  static const int hdMbps = 6;
  static const int maxFps = 30;
  static const int lowShortSide = 540;
  static const int lowMbps = 1;

  /// HD videos up to this bitrate are uploaded as they are.
  static const int keepBelowBps = 9000000;

  /// Small videos play fine anyway (no low copy).
  static int lowMinBytes = 3 * 1024 * 1024;

  static Duration timeout = const Duration(minutes: 6);

  static Future<void> _queue = Future<void>.value();

  /// Runs native compressions one after another (one hardware encoder).
  static Future<T> _serial<T>(Future<T> Function() job) {
    final c = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        c.complete(await job());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  static bool get _native =>
      !disabled && !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Decides the HD settings for a video (pure, tested).
  static HdPlan planHd({
    required int width,
    required int height,
    int? bitrate,
    double? fps,
  }) {
    if (width <= 0 || height <= 0) return const HdPlan(compress: false);
    final short = width < height ? width : height;
    final tooBig = short > hdShortSide;
    final tooFast = fps != null && fps > maxFps + 1;
    final tooHeavy = bitrate != null && bitrate > keepBelowBps;
    if (!tooBig && !tooFast && !tooHeavy) return const HdPlan(compress: false);
    final fpsOut = tooFast ? maxFps : null;
    final mbps = bitrate == null || bitrate <= 0
        ? hdMbps
        : (bitrate * 0.85 / 1000000).floor().clamp(2, hdMbps);
    if (!tooBig) {
      return HdPlan(compress: true, keepSize: true, fps: fpsOut, mbps: mbps);
    }
    final (w, h) = scaleTo(width, height, hdShortSide);
    return HdPlan(compress: true, width: w, height: h, fps: fpsOut, mbps: mbps);
  }

  /// Scales so the short side is [short] (keeps the shape, even numbers).
  static (int, int) scaleTo(int width, int height, int short) {
    final s = (width < height ? width : height).toDouble();
    if (s <= short) return (width & ~1, height & ~1);
    final f = short / s;
    int even(double v) => (v.round() ~/ 2) * 2;
    return (even(width * f), even(height * f));
  }

  static Future<Directory> _outDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/uploads');
    await d.create(recursive: true);
    return d;
  }

  /// HD + fast start version of [video] (or [video] itself when nothing
  /// could be done). Never throws.
  static Future<File> hd(File video, {ValueChanged<double>? onProgress}) async {
    if (!_native) return video;
    try {
      return await _serial(() => _hd(video, onProgress));
    } catch (e) {
      debugPrint('hd video: $e');
      return video;
    }
  }

  static Future<File> _hd(File video, ValueChanged<double>? onProgress) async {
    final lc = LightCompressor();
    MediaInfo? info;
    try {
      info = await lc.getMediaInfo(video.path);
    } catch (_) {}
    final plan = planHd(
      width: info?.width ?? 0,
      height: info?.height ?? 0,
      bitrate: info?.bitrate,
      fps: info?.frameRate,
    );
    debugPrint('hd plan: $plan  (${info?.width}x${info?.height})');
    File source = video;
    File? made;
    if (plan.compress) {
      final sub = lc.onProgressUpdated.listen(
        (p) => onProgress?.call((p / 100).clamp(0.0, 1.0)),
      );
      try {
        final r = await lc
            .compressVideo(
              path: video.path,
              videoQuality: VideoQuality.high,
              isMinBitrateCheckEnabled: false,
              android: AndroidConfig(isSharedStorage: false),
              ios: IOSConfig(saveInGallery: false),
              video: Video(
                videoName: 'hd_${DateTime.now().microsecondsSinceEpoch}.mp4',
                keepOriginalResolution: plan.keepSize,
                videoWidth: plan.keepSize ? null : plan.width,
                videoHeight: plan.keepSize ? null : plan.height,
                videoBitrateInMbps: plan.mbps,
                videoFps: plan.fps,
              ),
            )
            .timeout(
              timeout,
              onTimeout: () {
                lc.cancelCompression();
                return const OnCancelled(isCancelled: true);
              },
            );
        if (r is OnSuccess) {
          final f = File(r.destinationPath);
          // keep it only when it really is smaller
          if (await f.exists() && await f.length() < await video.length()) {
            source = made = f;
          } else if (await f.exists()) {
            unawaited(_delete(f));
          }
        } else {
          debugPrint('hd video: $r');
        }
      } finally {
        await sub.cancel();
      }
    }
    final fast = await Mp4FastStart.process(
      source,
      output: File(
        '${(await _outDir()).path}/v_${DateTime.now().microsecondsSinceEpoch}.mp4',
      ),
    );
    if (fast != null) {
      if (made != null) unawaited(_delete(made));
      return fast;
    }
    if (made != null) {
      // move it next to our other upload files (survives app restarts)
      try {
        return await made.rename(
          '${(await _outDir()).path}/v_${DateTime.now().microsecondsSinceEpoch}.mp4',
        );
      } catch (_) {
        return made;
      }
    }
    return video;
  }

  /// Small copy for slow networks, or null (small video / failed).
  static Future<File?> low(File video) async {
    if (!_native) return null;
    try {
      if (await video.length() < lowMinBytes) return null;
      return await _serial(() => _low(video));
    } catch (e) {
      debugPrint('low copy: $e');
      return null;
    }
  }

  static Future<File?> _low(File video) async {
    final lc = LightCompressor();
    MediaInfo? info;
    try {
      info = await lc.getMediaInfo(video.path);
    } catch (_) {}
    final w = info?.width ?? 0;
    final h = info?.height ?? 0;
    final small = w > 0 && h > 0;
    final (lw, lh) = small ? scaleTo(w, h, lowShortSide) : (0, 0);
    final r = await lc
        .compressVideo(
          path: video.path,
          videoQuality: VideoQuality.low,
          isMinBitrateCheckEnabled: false,
          android: AndroidConfig(isSharedStorage: false),
          ios: IOSConfig(saveInGallery: false),
          video: Video(
            videoName: 'low_${DateTime.now().microsecondsSinceEpoch}.mp4',
            videoWidth: small ? lw : null,
            videoHeight: small ? lh : null,
            videoBitrateInMbps: lowMbps,
            videoFps: maxFps,
          ),
        )
        .timeout(
          timeout,
          onTimeout: () {
            lc.cancelCompression();
            return const OnCancelled(isCancelled: true);
          },
        );
    if (r is! OnSuccess) return null;
    final out = File(r.destinationPath);
    if (!await out.exists()) return null;
    if (await out.length() > await video.length() * 0.6) {
      unawaited(_delete(out));
      return null;
    }
    final fast = await Mp4FastStart.process(
      out,
      output: File(
        '${(await _outDir()).path}/l_${DateTime.now().microsecondsSinceEpoch}.mp4',
      ),
    );
    if (fast != null) {
      unawaited(_delete(out));
      return fast;
    }
    return out;
  }

  /// True for files this class made (safe to delete after upload).
  static Future<bool> isOurs(File f) async {
    try {
      final d = await _outDir();
      return f.path.startsWith(d.path) ||
          f.uri.pathSegments.last.startsWith('hd_') ||
          f.uri.pathSegments.last.startsWith('low_');
    } catch (_) {
      return false;
    }
  }

  static Future<void> _delete(File f) =>
      f.delete().then((_) {}, onError: (Object _) {});
}
