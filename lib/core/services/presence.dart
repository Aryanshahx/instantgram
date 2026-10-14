import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_clock.dart';

/// What we know about someone's activity.
class PresenceState {
  const PresenceState(this.last, {this.online});

  /// Last time the app was open (server time).
  final DateTime? last;

  /// v0.11: true while their app is open, false after they left.
  /// null = an older app version (only [last] is known).
  final bool? online;
}

/// "Active now" / "Active 5m ago" (v0.10, v0.11).
///
/// Saved in presence/{uid} = {lastActive, hidden, online}. Not on the user
/// doc, so the profile is not re-sent to everyone every minute.
/// v0.11: "online" goes false as soon as you leave the app, so "Active now"
/// stops right away (before it stayed for 3 minutes).
/// Settings -> Activity status: off = you are hidden AND you don't see
/// other people's status (like Instagram).
class Presence with WidgetsBindingObserver {
  Presence._();
  static final Presence instance = Presence._();

  static const _kShow = 'show_activity';

  /// Old app versions (no "online" flag): active within this time = now.
  static const Duration nowWindow = Duration(minutes: 3);

  /// Online flag is trusted for this long after the last "I'm here"
  /// (when the phone dies, nobody writes "online: false").
  static const Duration onlineWindow = Duration(seconds: 150);

  /// How often "I'm here" is saved while the app is open.
  static const Duration beat = Duration(seconds: 60);

  /// Your setting (true = show + see others).
  final ValueNotifier<bool> show = ValueNotifier(true);

  String? _uid;
  Timer? _timer;
  bool _started = false;
  bool _online = false;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      FirebaseFirestore.instance.collection('presence').doc(uid);

  /// After login.
  Future<void> start(String uid) async {
    _uid = uid;
    try {
      final p = await SharedPreferences.getInstance();
      show.value = p.getBool(_kShow) ?? true;
    } catch (_) {}
    if (!_started) {
      _started = true;
      WidgetsBinding.instance.addObserver(this);
    }
    _resume();
  }

  /// Before logout: say "last active now, offline" and stop.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
      _started = false;
    }
    _online = false;
    await _write();
    _uid = null;
  }

  Future<void> setShow(bool v) async {
    show.value = v;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kShow, v);
    } catch (_) {}
    await _write();
  }

  void _resume() {
    _online = true;
    _timer?.cancel();
    _timer = Timer.periodic(beat, (_) => _write());
    _write();
  }

  void _leave() {
    if (!_online && _timer == null) return;
    _timer?.cancel();
    _timer = null;
    _online = false;
    _write(); // last active = when you left
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_uid == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _resume();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _leave();
      case AppLifecycleState.inactive:
        break; // notification shade, call screen ... still here
    }
  }

  Future<void> _write() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final sentAt = DateTime.now();
      await _doc(uid).set(
        show.value
            ? {
                'lastActive': FieldValue.serverTimestamp(),
                'hidden': false,
                'online': _online,
              }
            : {'lastActive': null, 'hidden': true, 'online': false},
      );
      if (show.value) unawaited(_learnClock(uid, sentAt, DateTime.now()));
    } catch (e) {
      debugPrint('presence: $e');
    }
  }

  /// Phone clock vs server clock, from the time the server just saved
  /// (read from the local cache: free).
  Future<void> _learnClock(String uid, DateTime sentAt, DateTime doneAt) async {
    try {
      final d = await _doc(uid).get(const GetOptions(source: Source.cache));
      final t = d.data()?['lastActive'];
      if (t is Timestamp) ServerClock.learn(t.toDate(), sentAt, doneAt);
    } catch (_) {}
  }

  /// Activity of [uid], or null (hidden / unknown / you hid yours).
  Stream<PresenceState?> watch(String uid) {
    if (!show.value) return Stream.value(null);
    // Firestore shares one listener per doc; keep the stream in a State.
    return _doc(uid).snapshots().map(fromMap);
  }

  static PresenceState? fromMap(DocumentSnapshot<Map<String, dynamic>> d) =>
      parse(d.data());

  static PresenceState? parse(Map<String, dynamic>? m) {
    if (m == null || m['hidden'] == true) return null;
    final t = m['lastActive'];
    if (t is! Timestamp) return null;
    final o = m['online'];
    return PresenceState(t.toDate(), online: o is bool ? o : null);
  }

  /// "Active now", "Active just now", "Active 5m ago", "Active 3h ago",
  /// "Active 2d ago" or null (more than a week, or unknown).
  static String? label(DateTime? last, {DateTime? now, bool? online}) {
    if (last == null) return null;
    final d = (now ?? ServerClock.now()).difference(last);
    if (isNow(last, now: now, online: online)) return 'Active now';
    if (d.inMinutes < 1) return 'Active just now';
    if (d.inMinutes < 60) return 'Active ${d.inMinutes}m ago';
    if (d.inHours < 24) return 'Active ${d.inHours}h ago';
    if (d.inDays < 7) return 'Active ${d.inDays}d ago';
    return null;
  }

  static bool isNow(DateTime? last, {DateTime? now, bool? online}) {
    if (last == null || online == false) return false;
    final d = (now ?? ServerClock.now()).difference(last);
    // a little clock difference is fine
    if (d < const Duration(seconds: -90)) return online == true;
    return d < (online == true ? onlineWindow : nowWindow);
  }

  static String? labelOf(PresenceState? s, {DateTime? now}) =>
      s == null ? null : label(s.last, now: now, online: s.online);

  static bool isNowOf(PresenceState? s, {DateTime? now}) =>
      s != null && isNow(s.last, now: now, online: s.online);
}
