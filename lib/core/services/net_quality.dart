import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../../shared/models/post.dart';
import 'video_cache.dart';

/// v0.14: how fast videos really download (measured by the video cache).
class Bandwidth {
  Bandwidth._();

  static double? _kbps;
  static int _samples = 0;

  /// Full HD clips need about 6 Mbps; with less than ~1.5x that, they
  /// wait before they start.
  static const double fastKbps = 9000;

  /// Measured speed in kbit/s (null = not measured yet).
  static double? get kbps => _kbps;

  static bool get fast => (_kbps ?? 0) >= fastKbps;

  /// [bytes] arrived in [ms] (small pieces say nothing: skipped).
  static void add(int bytes, int ms) {
    if (bytes < 192 * 1024 || ms <= 0) return;
    final k = bytes * 8 / ms;
    final old = _kbps;
    // new measurements count more (the network changes quickly)
    _kbps = old == null ? k : old * 0.55 + k * 0.45;
    _samples++;
  }

  static int get samples => _samples;

  @visibleForTesting
  static void reset() {
    _kbps = null;
    _samples = 0;
  }
}

/// v0.14 (like Reels): a clip starts with the small copy unless the full
/// one can start at once: it is already on the phone, or the network was
/// measured fast. When a video buffers, players switch to the small copy
/// and new videos use it for a few minutes.
class NetQuality {
  NetQuality._();

  static DateTime _slowUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// How long to stay on the small copies after buffering.
  static Duration slowFor = const Duration(minutes: 3);

  /// Waiting this long for the first frame counts as buffering.
  static Duration startTimeout = const Duration(milliseconds: 1500);

  /// Saved bytes that let a copy start at once (the player wants about
  /// 2.5 s of video before it starts).
  static int fullStartBytes = 2200 * 1024;

  static bool get slow => DateTime.now().isBefore(_slowUntil);

  static void markSlow() => _slowUntil = DateTime.now().add(slowFor);

  @visibleForTesting
  static void reset() => _slowUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// The url a player should open for [m] right now.
  static String urlFor(MediaItem m) {
    if (m.lowUrl.isEmpty) return m.url;
    if (slow) return m.lowUrl;
    if (VideoCache.instance.knownBytes(m.url) >= fullStartBytes) return m.url;
    return Bandwidth.fast ? m.url : m.lowUrl;
  }

  /// How much of the next clips to download ahead (the small copy almost
  /// whole: about 20 s).
  static int prefetchBytesFor(MediaItem m) =>
      urlFor(m) == m.lowUrl && m.lowUrl.isNotEmpty ? 2600 * 1024 : 3 * 1024 * 1024;

  /// Small autoplay tiles (Explore) never need full quality.
  static String tileUrl(MediaItem m) => m.lowUrl.isNotEmpty ? m.lowUrl : m.url;
}

/// Calls [onStall] once when a playing video keeps buffering for [after].
class StallWatch {
  StallWatch(
    this.controller, {
    required this.onStall,
    this.after = const Duration(milliseconds: 1200),
  }) {
    controller.addListener(_check);
  }

  final VideoPlayerController controller;
  final VoidCallback onStall;
  final Duration after;
  Timer? _timer;
  bool _fired = false;

  void _check() {
    final v = controller.value;
    if (v.isInitialized && v.isPlaying && v.isBuffering) {
      _timer ??= Timer(after, () {
        if (_fired) return;
        _fired = true;
        onStall();
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void dispose() {
    _timer?.cancel();
    controller.removeListener(_check);
  }
}
