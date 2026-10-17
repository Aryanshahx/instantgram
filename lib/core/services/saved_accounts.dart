import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/models/user_profile.dart';
import 'account_family.dart';

/// One account saved on this phone (Settings -> Accounts).
@immutable
class SavedAccount {
  const SavedAccount({
    required this.uid,
    required this.email,
    this.username = '',
    this.name = '',
    this.photoUrl = '',
    this.linked = false,
  });

  final String uid;
  final String email;
  final String username;
  final String name;
  final String photoUrl;

  /// v0.0.2: an account of the same login (no own password; switching
  /// goes through our server, see AccountFamily).
  final bool linked;

  String get label => username.isNotEmpty ? '@$username' : email;

  SavedAccount copyWith({
    String? email,
    String? username,
    String? name,
    String? photoUrl,
    bool? linked,
  }) => SavedAccount(
    uid: uid,
    email: email ?? this.email,
    username: username ?? this.username,
    name: name ?? this.name,
    photoUrl: photoUrl ?? this.photoUrl,
    linked: linked ?? this.linked,
  );

  Map<String, dynamic> toJson() => {
    'uid': uid,
    'email': email,
    'username': username,
    'name': name,
    'photoUrl': photoUrl,
    if (linked) 'linked': true,
  };

  static SavedAccount? fromJson(Object? j) {
    if (j is! Map) return null;
    final uid = j['uid'];
    final email = j['email'];
    if (uid is! String || uid.isEmpty || email is! String) return null;
    String s(Object? v) => v is String ? v : '';
    return SavedAccount(
      uid: uid,
      email: email,
      username: s(j['username']),
      name: s(j['name']),
      photoUrl: s(j['photoUrl']),
      linked: j['linked'] == true,
    );
  }
}

/// v0.12: accounts you used on this phone, for quick switching.
/// The list and the passwords stay ONLY on this phone (app storage, the
/// password scrambled with a random key made on this phone). Nothing is
/// sent anywhere. "Remove" forgets an account.
class SavedAccounts {
  SavedAccounts._();
  static final SavedAccounts instance = SavedAccounts._();

  static const int max = 5;
  static const _listKey = 'saved_accounts_v1';
  static const _keyKey = 'saved_accounts_k';
  static String _pwKey(String uid) => 'acct_pw_$uid';

  final ValueNotifier<List<SavedAccount>> accounts = ValueNotifier(const []);
  bool _loaded = false;

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<List<SavedAccount>> load() async {
    if (_loaded) return accounts.value;
    final p = await _prefs;
    final raw = p.getString(_listKey);
    var list = <SavedAccount>[];
    if (raw != null) {
      try {
        list = (jsonDecode(raw) as List)
            .map(SavedAccount.fromJson)
            .whereType<SavedAccount>()
            .toList();
      } catch (_) {}
    }
    accounts.value = List.unmodifiable(list);
    _loaded = true;
    return accounts.value;
  }

  Future<void> _write(List<SavedAccount> list) async {
    accounts.value = List.unmodifiable(list);
    final p = await _prefs;
    await p.setString(
      _listKey,
      jsonEncode(list.map((a) => a.toJson()).toList()),
    );
  }

  /// After a successful login / sign up.
  Future<void> rememberLogin({
    required String uid,
    required String email,
    required String password,
  }) async {
    final list = [...await load()];
    final i = list.indexWhere((a) => a.uid == uid);
    if (i >= 0) {
      list[i] = list[i].copyWith(email: email);
    } else {
      list.add(SavedAccount(uid: uid, email: email));
    }
    final kept = await _trim(list, keepUid: uid);
    await _write(kept);
    final p = await _prefs;
    await p.setString(_pwKey(uid), scramble(password, await _key()));
  }

  /// v0.0.2: the accounts of your login ([AccountFamily]) for the switcher.
  /// Accounts saved with a password stay as they are.
  Future<void> rememberFamily(
    List<FamilyAccount> family, {
    String email = '',
  }) async {
    final list = [...await load()];
    // the login's email: given, else from a saved account of this login
    var mail = email;
    if (mail.isEmpty) {
      for (final a in list) {
        if (a.email.isNotEmpty && family.any((f) => f.uid == a.uid)) {
          mail = a.email;
          break;
        }
      }
    }
    for (final f in family) {
      final uid = f.uid;
      final i = list.indexWhere((a) => a.uid == uid);
      if (i >= 0) {
        list[i] = list[i].copyWith(
          username: f.username,
          name: f.name,
          photoUrl: f.photoUrl,
        );
        continue;
      }
      if (list.length >= max) continue;
      list.add(
        SavedAccount(
          uid: uid,
          email: mail,
          username: f.username,
          name: f.name,
          photoUrl: f.photoUrl,
          linked: true,
        ),
      );
    }
    await _write(list);
  }

  /// v0.0.2: a saved password for [email] (any account of that login).
  Future<String?> passwordForEmail(String email) async {
    final e = email.trim().toLowerCase();
    if (e.isEmpty) return null;
    for (final a in await load()) {
      if (a.email.trim().toLowerCase() != e) continue;
      final pw = await password(a.uid);
      if (pw != null) return pw;
    }
    return null;
  }

  /// Keeps name / photo up to date (Settings -> Accounts opens).
  Future<void> updateProfile(UserProfile me) async {
    if (me.uid.isEmpty) return;
    final list = [...await load()];
    final i = list.indexWhere((a) => a.uid == me.uid);
    final next = (i >= 0
            ? list[i]
            : SavedAccount(uid: me.uid, email: me.email))
        .copyWith(
          email: me.email.isNotEmpty ? me.email : null,
          username: me.username,
          name: me.name,
          photoUrl: me.photoUrl,
        );
    if (i >= 0) {
      if (list[i].toJson().toString() == next.toJson().toString()) return;
      list[i] = next;
    } else {
      if (next.email.isEmpty) return;
      list.add(next);
    }
    await _write(await _trim(list, keepUid: me.uid));
  }

  Future<List<SavedAccount>> _trim(
    List<SavedAccount> list, {
    required String keepUid,
  }) async {
    if (list.length <= max) return list;
    final p = await _prefs;
    while (list.length > max) {
      final i = list.indexWhere((a) => a.uid != keepUid);
      await p.remove(_pwKey(list[i].uid));
      list.removeAt(i);
    }
    return list;
  }

  /// Saved password, or null.
  Future<String?> password(String uid) async {
    final p = await _prefs;
    final s = p.getString(_pwKey(uid));
    if (s == null || s.isEmpty) return null;
    final pw = unscramble(s, await _key());
    return pw.isEmpty ? null : pw;
  }

  Future<void> forgetPassword(String uid) async =>
      (await _prefs).remove(_pwKey(uid));

  Future<void> remove(String uid) async {
    final list = [...await load()]..removeWhere((a) => a.uid == uid);
    await _write(list);
    await forgetPassword(uid);
  }

  Future<List<int>> _key() async {
    final p = await _prefs;
    final k = p.getString(_keyKey);
    if (k != null) {
      try {
        final b = base64Decode(k);
        if (b.length >= 16) return b;
      } catch (_) {}
    }
    final r = Random.secure();
    final b = List<int>.generate(32, (_) => r.nextInt(256));
    await p.setString(_keyKey, base64Encode(b));
    return b;
  }

  /// Not plain text in the app storage (key made on this phone).
  static String scramble(String text, List<int> key) {
    final b = utf8.encode(text);
    return base64Encode([
      for (var i = 0; i < b.length; i++) b[i] ^ key[(i * 7 + 3) % key.length],
    ]);
  }

  static String unscramble(String s, List<int> key) {
    try {
      final b = base64Decode(s);
      return utf8.decode([
        for (var i = 0; i < b.length; i++)
          b[i] ^ key[(i * 7 + 3) % key.length],
      ]);
    } catch (_) {
      return '';
    }
  }

  /// Tests.
  @visibleForTesting
  void debugReset() {
    _loaded = false;
    accounts.value = const [];
  }
}
