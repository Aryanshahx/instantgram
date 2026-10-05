import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:volume_controller/volume_controller.dart';

/// The phone's real media volume (the same one the volume buttons change).
abstract class VolumeBackend {
  Future<double> get();
  Future<void> set(double v);

  /// Calls [onChange] when the volume changes (volume buttons). Returns a way to stop.
  VoidCallback listen(void Function(double v) onChange);
}

class PluginVolumeBackend implements VolumeBackend {
  @override
  Future<double> get() => VolumeController.instance.getVolume();

  @override
  Future<void> set(double v) async {
    VolumeController.instance.showSystemUI = false;
    await VolumeController.instance.setVolume(v);
  }

  @override
  VoidCallback listen(void Function(double v) onChange) {
    final sub = VolumeController.instance.addListener(onChange);
    return sub.cancel;
  }
}

/// Reads and sets the media volume of the phone. Any failure (no plugin, no permission) is
/// swallowed: the level is then only kept in the app.
class SystemVolume {
  SystemVolume._();
  static final SystemVolume instance = SystemVolume._();

  VolumeBackend backend = PluginVolumeBackend();

  /// 0..1, null until it is known.
  final ValueNotifier<double?> level = ValueNotifier<double?>(null);
  VoidCallback? _stop;

  /// When this app last changed the volume. The phone reports every change back a moment
  /// later (often out of order while sliding fast); those echoes must not move the level.
  DateTime _lastWrite = DateTime.fromMillisecondsSinceEpoch(0);
  bool _inFlight = false;
  double? _pending;

  /// Time during which reports from the phone are treated as echoes of our own writes.
  static const Duration echoWindow = Duration(milliseconds: 900);

  /// Reads the current volume and follows changes made with the buttons.
  Future<void> start() async {
    if (_stop != null) return;
    try {
      _stop = backend.listen((v) {
        if (DateTime.now().difference(_lastWrite) > echoWindow) {
          level.value = v.clamp(0.0, 1.0);
        }
      });
      level.value = (await backend.get()).clamp(0.0, 1.0);
    } catch (_) {
      // not available: keep working with the in-app level
    }
  }

  void stop() {
    _stop?.call();
    _stop = null;
  }

  /// Sets the volume. While a write is still running only the newest value is kept, so a
  /// fast slide sends a few writes (always ending on the last one) instead of a flood.
  Future<void> set(double v) async {
    final x = v.clamp(0.0, 1.0);
    level.value = x;
    _lastWrite = DateTime.now();
    if (_inFlight) {
      _pending = x;
      return;
    }
    _inFlight = true;
    var next = x;
    try {
      while (true) {
        try {
          await backend.set(next);
        } catch (_) {
          // see above
        }
        _lastWrite = DateTime.now();
        final p = _pending;
        _pending = null;
        if (p == null || (p - next).abs() < 0.001) break;
        next = p;
      }
    } finally {
      _inFlight = false;
    }
  }
}
