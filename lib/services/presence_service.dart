import 'dart:async';

import 'package:flutter/widgets.dart';

import 'user_service.dart';

/// How often the open app tells the others it is still here.
const Duration kPresenceBeat = Duration(minutes: 4);

/// Someone counts as "Active now" when the app was open within this time.
const Duration kActiveNowWindow = Duration(minutes: 6);

/// True when [lastActive] means the person has the app open right now.
bool isActiveNow(DateTime? lastActive, DateTime now) =>
    lastActive != null && now.difference(lastActive) < kActiveNowWindow;

/// "Active now", "Active 12m ago", "Active 3h ago", "Active yesterday", "Active 4d ago";
/// empty when unknown or longer than a week ago.
String presenceLabel(DateTime? lastActive, DateTime now) {
  if (lastActive == null) return '';
  if (isActiveNow(lastActive, now)) return 'Active now';
  final d = now.difference(lastActive);
  if (d.inMinutes < 60) return 'Active ${d.inMinutes}m ago';
  if (d.inHours < 24) return 'Active ${d.inHours}h ago';
  if (d.inDays < 2) return 'Active yesterday';
  if (d.inDays < 7) return 'Active ${d.inDays}d ago';
  return '';
}

/// Keeps `users/{me}.lastActive` fresh while the app is open (one small write every
/// [kPresenceBeat], plus one when the app opens and one when it closes).
class PresenceService with WidgetsBindingObserver {
  PresenceService._();
  static final PresenceService instance = PresenceService._();

  Timer? _timer;
  bool _started = false;
  DateTime? _lastWrite;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _resume();
  }

  void _resume() {
    _beat(force: true);
    _timer?.cancel();
    _timer = Timer.periodic(kPresenceBeat, (_) => _beat());
  }

  Future<void> _beat({bool force = false}) async {
    final now = DateTime.now();
    final last = _lastWrite;
    if (!force && last != null && now.difference(last) < kPresenceBeat ~/ 2) {
      return;
    }
    _lastWrite = now;
    try {
      await UserService.instance.markActive();
    } catch (_) {
      // offline or signed out: the next beat tries again
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resume();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _timer?.cancel();
      _timer = null;
      _beat(force: true); // "Active Xm ago" counts from when the app was left
    }
  }
}
