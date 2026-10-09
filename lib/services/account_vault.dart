import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Logins kept on this phone so accounts can be switched without typing the password again.
/// They are stored with flutter_secure_storage (Android Keystore encryption) and never leave
/// the phone.
class AccountVault {
  AccountVault._();
  static final AccountVault instance = AccountVault._();

  static const _key = 'ig_logins_v1';

  /// Tests keep the logins in this map instead of the real storage.
  Map<String, String>? debugStore;

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );

  Future<Map<String, Map<String, String>>> _all() async {
    try {
      final raw = debugStore != null
          ? debugStore![_key]
          : await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return {};
      final m = jsonDecode(raw);
      if (m is! Map) return {};
      final out = <String, Map<String, String>>{};
      m.forEach((k, v) {
        if (k is String && v is Map && v['e'] is String && v['p'] is String) {
          out[k] = {'e': v['e'] as String, 'p': v['p'] as String};
        }
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> _write(Map<String, Map<String, String>> all) async {
    final raw = jsonEncode(all);
    try {
      if (debugStore != null) {
        debugStore![_key] = raw;
      } else {
        await _storage.write(key: _key, value: raw);
      }
    } catch (_) {
      // nothing saved: the next switch asks for the password
    }
  }

  /// Keeps the login of [uid].
  Future<void> save(String uid, String email, String password) async {
    if (uid.isEmpty || email.isEmpty || password.isEmpty) return;
    final all = await _all();
    all[uid] = {'e': email, 'p': password};
    await _write(all);
  }

  /// The saved login of [uid] (email, password), or null.
  Future<(String, String)?> read(String uid) async {
    final v = (await _all())[uid];
    return v == null ? null : (v['e']!, v['p']!);
  }

  /// Accounts that can be switched to without a password.
  Future<Set<String>> uids() async => (await _all()).keys.toSet();

  Future<void> forget(String uid) async {
    final all = await _all();
    if (all.remove(uid) != null) await _write(all);
  }
}
