import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../../shared/models/post.dart';

/// Full quality by default. When a video buffers, players switch to the
/// smaller copy and new videos start with it for a few minutes.
class NetQuality {
  NetQuality._();

  static DateTime _slowUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// How long to stay on the small copies after buffering.
  static Duration slowFor = const Duration(minutes: 3);

  /// Waiting this long for the first frame counts as buffering.
  static Duration startTimeout = const Duration(milliseconds: 2500);

  static bool get slow => DateTime.now().isBefore(_slowUntil);

  static void markSlow() => _slowUntil = DateTime.now().add(slowFor);

  @visibleForTesting
  static void reset() => _slowUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// The url a player should open for [m] right now.
  static String urlFor(MediaItem m) =>
      slow && m.lowUrl.isNotEmpty ? m.lowUrl : m.url;

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
