import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'saved_accounts.dart';

/// One account of your login (see [AccountFamily]).
@immutable
class FamilyAccount {
  const FamilyAccount({
    required this.uid,
    this.username = '',
    this.name = '',
    this.photoUrl = '',
  });

  final String uid;
  final String username;
  final String name;
  final String photoUrl;

  static FamilyAccount? fromMap(Object? v) {
    if (v is! Map) return null;
    final uid = v['uid'];
    if (uid is! String || uid.isEmpty) return null;
    String s(Object? x) => x is String ? x : '';
    return FamilyAccount(
      uid: uid,
      username: s(v['username']),
      name: s(v['name']),
      photoUrl: s(v['photoUrl']),
    );
  }
}

/// v0.0.2: many accounts with ONE email + password.
///
/// You log in once, then choose the account. New accounts are made by our
/// server (Settings -> Accounts -> "New account, same login"); switching
/// asks the server for a one-time sign-in token, so no extra passwords.
class AccountFamily {
  AccountFamily._();
  static final AccountFamily instance = AccountFamily._();

  /// Max accounts on one login (same as the server).
  static const int max = 5;

  /// Server call (tests replace it).
  Future<Map<String, dynamic>> Function(Map<String, dynamic> body) call =
      (body) => ApiClient.instance.post('/api/accounts', body);

  /// Firebase sign in with the server's token (tests replace it).
  Future<void> Function(String token) signInWithToken = (token) async {
    await FirebaseAuth.instance.signInWithCustomToken(token);
  };

  /// Your login's accounts (after [refresh]).
  final ValueNotifier<List<FamilyAccount>> accounts = ValueNotifier(const []);

  /// Set by the login screen: show "Choose account" after logging in.
  bool askAfterLogin = false;

  /// Logged in with the username of one of the accounts: open it.
  String wantUid = '';

  bool contains(String uid) => accounts.value.any((a) => a.uid == uid);

  /// Reads the accounts from the server and saves them on this phone
  /// (for the account switcher).
  Future<List<FamilyAccount>> refresh({String email = ''}) async {
    final r = await call({'action': 'list'});
    final raw = r['accounts'];
    final list = raw is List
        ? raw.map(FamilyAccount.fromMap).whereType<FamilyAccount>().toList()
        : <FamilyAccount>[];
    accounts.value = List.unmodifiable(list);
    if (list.length > 1) {
      try {
        await SavedAccounts.instance.rememberFamily(list, email: email);
      } catch (e) {
        debugPrint('saved accounts: $e');
      }
    }
    return list;
  }

  /// Sign-in tokens fetched early (uid -> token, when). Firebase accepts
  /// them for 1 hour; we use them for 45 minutes.
  final Map<String, (String, DateTime)> _tokens = {};
  static const Duration tokenLife = Duration(minutes: 45);

  /// Clock (tests).
  DateTime Function() now = DateTime.now;

  /// Gets the sign-in tokens of [uids] now (the account switcher opened),
  /// so tapping an account switches at once. Errors are ignored.
  Future<void> prefetch(Iterable<String> uids, {required String me}) async {
    final want = {
      for (final u in uids)
        if (u.isNotEmpty && u != me && !_fresh(u)) u,
    };
    await Future.wait([
      for (final u in want)
        _fetchToken(u).then(
          (t) => _tokens[u] = (t, now()),
          onError: (Object e) {
            debugPrint('prefetch $u: $e');
            return ('', now());
          },
        ),
    ]);
  }

  bool _fresh(String uid) {
    final c = _tokens[uid];
    return c != null && c.$1.isNotEmpty && now().difference(c.$2) < tokenLife;
  }

  /// One-time sign-in token for [uid] (must be one of your accounts).
  Future<String> tokenFor(String uid) async {
    if (_fresh(uid)) return _tokens.remove(uid)!.$1;
    _tokens.remove(uid);
    return _fetchToken(uid);
  }

  Future<String> _fetchToken(String uid) async {
    final r = await call({'action': 'switch', 'uid': uid});
    final t = r['token'];
    if (t is! String || t.isEmpty) {
      throw const ApiException('Could not switch account. Try again.');
    }
    return t;
  }

  /// Makes a new account on your login -> (uid, sign-in token).
  Future<(String, String)> create({
    required String username,
    required String name,
  }) async {
    final r = await call({
      'action': 'create',
      'username': username.trim().toLowerCase(),
      'name': name.trim(),
    });
    final uid = r['uid'], t = r['token'];
    if (uid is! String || t is! String || uid.isEmpty || t.isEmpty) {
      throw const ApiException('Could not create the account. Try again.');
    }
    return (uid, t);
  }

  /// Logout of everything.
  void clear() {
    accounts.value = const [];
    _tokens.clear();
  }

  /// Forget the login flags (failed login) and the list.
  void resetLogin() {
    accounts.value = const [];
    askAfterLogin = false;
    wantUid = '';
  }
}
