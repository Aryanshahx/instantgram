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
  bool _writing = false;

  /// Reads the current volume and follows changes made with the buttons.
  Future<void> start() async {
    if (_stop != null) return;
    try {
      _stop = backend.listen((v) {
        if (!_writing) level.value = v.clamp(0.0, 1.0);
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

  Future<void> set(double v) async {
    final x = v.clamp(0.0, 1.0);
    level.value = x;
    _writing = true;
    try {
      await backend.set(x);
    } catch (_) {
      // see above
    } finally {
      Future<void>.delayed(
        const Duration(milliseconds: 250),
        () => _writing = false,
      );
    }
  }
}
