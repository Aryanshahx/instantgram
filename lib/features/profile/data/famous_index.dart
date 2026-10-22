import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Famous" accounts = 10,000+ followers. Their posts and moments show
/// in everyone's Discover feed (together with the people you follow).
class FamousIndex {
  FamousIndex._();
  static final FamousIndex instance = FamousIndex._();

  static const int minFollowers = 10000;
  static const int maxAccounts = 200;

  /// uids of famous accounts (most followers first).
  final ValueNotifier<List<String>> ids = ValueNotifier(const <String>[]);

  /// True after the first answer from the server/cache.
  final ValueNotifier<bool> ready = ValueNotifier(false);

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;

  /// How many app screens use it (an account switch can start the new one
  /// before the old one stops; the list keeps running for the new one).
  int _users = 0;

  static const _saveKey = 'famous_ids_v1';

  bool isFamous(String uid) => ids.value.contains(uid);

  void start() {
    _users++;
    if (_sub != null) return;
    // the same for every account: the last list shows at once (new account,
    // account switch, app start) while the fresh one loads
    if (ids.value.isEmpty) unawaited(_loadSaved());
    _sub = FirebaseFirestore.instance
        .collection('users')
        .where('followersCount', isGreaterThanOrEqualTo: minFollowers)
        .orderBy('followersCount', descending: true)
        .limit(maxAccounts)
        .snapshots()
        .listen((s) {
          final list = s.docs.map((d) => d.id).toList();
          _fresh = true;
          if (!listEquals(list, ids.value)) {
            ids.value = list;
            unawaited(_save(list));
          }
          ready.value = true;
        }, onError: (Object _) => ready.value = true);
  }

  /// Got the list from Firestore (the saved one must not replace it).
  bool _fresh = false;

  Future<void> _loadSaved() async {
    try {
      final p = await SharedPreferences.getInstance();
      final saved = p.getStringList(_saveKey);
      if (saved == null || saved.isEmpty || _fresh || ids.value.isNotEmpty) {
        return;
      }
      ids.value = List.unmodifiable(saved);
    } catch (_) {}
  }

  Future<void> _save(List<String> list) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_saveKey, list);
    } catch (_) {}
  }

  /// Keeps the list (famous people are the same for every account), so the
  /// next account's feed doesn't wait for it again.
  void stop() {
    if (_users > 0) _users--;
    if (_users > 0) return;
    _sub?.cancel();
    _sub = null;
    _fresh = false;
  }

  @visibleForTesting
  void debugSet(List<String> list) {
    ids.value = list;
    ready.value = true;
  }
}

/// Who fills my Discover feed + moments row: me, people I follow, famous.
/// Order = me, following, famous (no duplicates).
List<String> feedAuthors(
  String me,
  List<String> following,
  List<String> famous, {
  int max = 300,
}) {
  final out = <String>{me, ...following, ...famous};
  return out.take(max).toList();
}
