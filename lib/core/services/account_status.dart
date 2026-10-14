import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// v0.13: things only the admin website can change.
/// - verified badges: `config/verified.uids` (users can't write it, so a
///   badge can't be faked),
/// - blocked (banned) accounts: `users/{uid}.banned`.
class AccountStatus {
  AccountStatus._();
  static final AccountStatus instance = AccountStatus._();

  /// Users with the blue badge.
  final ValueNotifier<Set<String>> verified = ValueNotifier(const {});

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _verifiedSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _banSub;
  bool _bannedShown = false;

  bool isVerified(String uid) => uid.isNotEmpty && verified.value.contains(uid);

  /// Reads the `uids` list of `config/verified`.
  static Set<String> uidsOf(Map<String, dynamic>? data) {
    final v = data?['uids'];
    if (v is! List) return const {};
    return v.whereType<String>().where((s) => s.isNotEmpty).toSet();
  }

  void start(String uid, {required VoidCallback onBanned}) {
    stop();
    _bannedShown = false;
    final db = FirebaseFirestore.instance;
    _verifiedSub = db
        .doc('config/verified')
        .snapshots()
        .listen(
          (d) => verified.value = uidsOf(d.data()),
          onError: (Object e) => debugPrint('verified: $e'),
        );
    _banSub = db.doc('users/$uid').snapshots().listen((d) {
      if (d.data()?['banned'] == true && !_bannedShown) {
        _bannedShown = true;
        onBanned();
      }
    }, onError: (Object e) => debugPrint('ban watch: $e'));
  }

  void stop() {
    _verifiedSub?.cancel();
    _verifiedSub = null;
    _banSub?.cancel();
    _banSub = null;
  }

  @visibleForTesting
  void debugSetVerified(Set<String> uids) => verified.value = uids;
}
