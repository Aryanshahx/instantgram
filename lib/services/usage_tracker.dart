import 'dart:async';

import 'package:flutter/widgets.dart';

import 'app_prefs.dart';

/// Counts how long the app is open each day (for Settings > Manage time) and tells the
/// shell when the daily limit is reached.
class UsageTracker with WidgetsBindingObserver {
  UsageTracker._();
  static final UsageTracker instance = UsageTracker._();

  /// Becomes true once per day, when today's time passes the daily limit.
  final ValueNotifier<bool> limitReached = ValueNotifier(false);

  Timer? _timer;
  DateTime? _since;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _resume();
  }

  void _resume() {
    _since = DateTime.now();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _flush());
  }

  /// Adds the time since the last flush to today (a day change is split at midnight).
  void _flush() {
    final from = _since;
    if (from == null) return;
    final now = DateTime.now();
    _since = now;
    var a = from;
    while (AppPrefs.dayKey(a) != AppPrefs.dayKey(now)) {
      final midnight = DateTime(a.year, a.month, a.day + 1);
      AppPrefs.instance.addUsage(a, midnight.difference(a).inSeconds);
      a = midnight;
    }
    AppPrefs.instance.addUsage(now, now.difference(a).inSeconds);
    _checkLimit(now);
  }

  void _checkLimit(DateTime now) {
    final limit = AppPrefs.instance.dailyLimitMinutes;
    if (limit <= 0) return;
    if (AppPrefs.instance.usageSeconds(now) < limit * 60) return;
    if (AppPrefs.instance.limitShownDay == AppPrefs.dayKey(now)) return;
    AppPrefs.instance.limitShownDay = AppPrefs.dayKey(now);
    limitReached.value = true;
  }

  /// Seconds spent today, including the running session.
  int todaySeconds() {
    _flush();
    return AppPrefs.instance.usageSeconds(DateTime.now());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resume();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _flush();
      _timer?.cancel();
      _since = null;
    }
  }
}
