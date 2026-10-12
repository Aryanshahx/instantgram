import 'package:volume_controller/volume_controller.dart';

/// The phone's media volume (same as the volume buttons), 0..1.
/// Works without showing the system volume bar.
class SystemVolume {
  SystemVolume._();
  static final SystemVolume instance = SystemVolume._();

  /// Last known value (used when the phone can't tell us).
  double value = 1;
  bool _ready = false;

  void _init() {
    if (_ready) return;
    _ready = true;
    try {
      VolumeController.instance.showSystemUI = false;
    } catch (_) {}
  }

  Future<double> get() async {
    _init();
    try {
      value = (await VolumeController.instance.getVolume()).clamp(0.0, 1.0);
    } catch (_) {}
    return value;
  }

  Future<void> set(double v) async {
    _init();
    value = v.clamp(0.0, 1.0);
    try {
      await VolumeController.instance.setVolume(value);
    } catch (_) {}
  }
}
