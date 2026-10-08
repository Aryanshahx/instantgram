import 'dart:async';

import 'package:flutter/widgets.dart';

import 'user_service.dart';

/// How often the open app tells the others it is still here.
const Duration kPresenceBeat = Duration(minutes: 2);

/// Someone counts as "Active now" when the app was open within this time (and did not
/// say it closed). Covers a phone that died without saying goodbye.
const Duration kActiveNowWindow = Duration(minutes: 4);

/// True when the person has the app open right now. [online] is false as soon as they
/// leave the app (older app versions never send it, so it defaults to true).
bool isActiveNow(DateTime? lastActive, DateTime now, {bool online = true}) =>
    online &&
    lastActive != null &&
    now.difference(lastActive) < kActiveNowWindow;

/// "Active now", "Active just now", "Active 12m ago", "Active 3h ago", "Active yesterday",
/// "Active 4d ago"; empty when unknown or longer than a week ago.
String presenceLabel(DateTime? lastActive, DateTime now, {bool online = true}) {
  if (lastActive == null) return '';
  if (isActiveNow(lastActive, now, online: online)) return 'Active now';
  final d = now.difference(lastActive);
  if (d.inMinutes < 1) return 'Active just now';
  if (d.inMinutes < 60) return 'Active ${d.inMinutes}m ago';
  if (d.inHours < 24) return 'Active ${d.inHours}h ago';
  if (d.inDays < 2) return 'Active yesterday';
  if (d.inDays < 7) return 'Active ${d.inDays}d ago';
  return '';
}

/// Keeps `users/{me}.lastActive` fresh while the app is open (one small write every
/// [kPresenceBeat]) and flips `online` the moment the app opens or goes to the background,
/// so the others see it straight away.
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
    _beat(force: true, online: true);
    _timer?.cancel();
    _timer = Timer.periodic(kPresenceBeat, (_) => _beat());
  }

  Future<void> _beat({bool force = false, bool online = true}) async {
    final now = DateTime.now();
    final last = _lastWrite;
    if (!force && last != null && now.difference(last) < kPresenceBeat ~/ 2) {
      return;
    }
    _lastWrite = now;
    try {
      await UserService.instance.markActive(online: online);
    } catch (_) {
      // offline or signed out: the next beat tries again
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resume();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      if (_timer == null) return; // already said goodbye
      _timer?.cancel();
      _timer = null;
      // offline at once; "Active Xm ago" counts from now
      _beat(force: true, online: false);
    }
  }
}
