import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

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

  bool isFamous(String uid) => ids.value.contains(uid);

  void start() {
    if (_sub != null) return;
    _sub = FirebaseFirestore.instance
        .collection('users')
        .where('followersCount', isGreaterThanOrEqualTo: minFollowers)
        .orderBy('followersCount', descending: true)
        .limit(maxAccounts)
        .snapshots()
        .listen((s) {
          final list = s.docs.map((d) => d.id).toList();
          if (!listEquals(list, ids.value)) ids.value = list;
          ready.value = true;
        }, onError: (Object _) => ready.value = true);
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    ids.value = const [];
    ready.value = false;
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
