import 'dart:async';

import 'package:flutter/widgets.dart';

import 'app_settings.dart';

/// Counts time while the app is open (for Settings → Manage time).
class UsageTracker with WidgetsBindingObserver {
  UsageTracker._();
  static final UsageTracker instance = UsageTracker._();

  final Stopwatch _watch = Stopwatch();
  Timer? _timer;
  bool _started = false;

  /// Called once a day when the daily limit is passed.
  VoidCallback? onLimitReached;

  void start() {
    if (_started) return;
    _started = true;
    AppSettings.instance.load();
    WidgetsBinding.instance.addObserver(this);
    _resume();
  }

  void stop() {
    if (!_started) return;
    _flush();
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
    _watch
      ..stop()
      ..reset();
  }

  void _resume() {
    _watch.start();
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) => _flush());
  }

  void _pause() {
    _flush();
    _watch.stop();
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _flush() async {
    final secs = _watch.elapsed.inSeconds;
    if (secs <= 0) return;
    _watch.reset(); // keeps running if it was running
    await AppSettings.instance.addUsage(secs);
    if (AppSettings.instance.shouldRemind()) {
      await AppSettings.instance.markReminded();
      onLimitReached?.call();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resume();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _pause();
    }
  }
}
