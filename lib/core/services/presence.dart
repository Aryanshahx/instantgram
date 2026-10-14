import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Active now" / "Active 5m ago" (v0.10).
///
/// Saved in presence/{uid} = {lastActive, hidden}. Not on the user doc,
/// so the profile is not re-sent to everyone every minute.
/// Settings -> Activity status: off = you are hidden AND you don't see
/// other people's status (like Instagram).
class Presence with WidgetsBindingObserver {
  Presence._();
  static final Presence instance = Presence._();

  static const _kShow = 'show_activity';

  /// Active within this time = "Active now".
  static const Duration nowWindow = Duration(minutes: 3);

  /// How often "I'm here" is saved while the app is open.
  static const Duration beat = Duration(minutes: 2);

  /// Your setting (true = show + see others).
  final ValueNotifier<bool> show = ValueNotifier(true);

  String? _uid;
  Timer? _timer;
  bool _started = false;

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

  /// Before logout: say "last active now" and stop.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
      _started = false;
    }
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
    _timer?.cancel();
    _timer = Timer.periodic(beat, (_) => _write());
    _write();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_uid == null) return;
    if (state == AppLifecycleState.resumed) {
      _resume();
    } else if (state == AppLifecycleState.paused) {
      _timer?.cancel();
      _timer = null;
      _write(); // last active = when you left
    }
  }

  Future<void> _write() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await _doc(uid).set(
        show.value
            ? {'lastActive': FieldValue.serverTimestamp(), 'hidden': false}
            : {'lastActive': null, 'hidden': true},
      );
    } catch (e) {
      debugPrint('presence: $e');
    }
  }

  /// Last time [uid] was active, or null (hidden / unknown / you hid yours).
  Stream<DateTime?> watch(String uid) {
    if (!show.value) return Stream.value(null);
    // Firestore shares one listener per doc; keep the stream in a State.
    return _doc(uid).snapshots().map((d) {
      final m = d.data();
      if (m == null || m['hidden'] == true) return null;
      final t = m['lastActive'];
      return t is Timestamp ? t.toDate() : null;
    });
  }

  /// "Active now", "Active 5m ago", "Active 3h ago", "Active 2d ago" or
  /// null (more than a week, or unknown).
  static String? label(DateTime? last, {DateTime? now}) {
    if (last == null) return null;
    final d = (now ?? DateTime.now()).difference(last);
    if (d < nowWindow) return 'Active now';
    if (d.inMinutes < 60) return 'Active ${d.inMinutes}m ago';
    if (d.inHours < 24) return 'Active ${d.inHours}h ago';
    if (d.inDays < 7) return 'Active ${d.inDays}d ago';
    return null;
  }

  static bool isNow(DateTime? last, {DateTime? now}) =>
      last != null && (now ?? DateTime.now()).difference(last) < nowWindow;
}
