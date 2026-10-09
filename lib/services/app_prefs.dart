import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A remembered account (for "Add account" / "Switch account").
class SavedAccount {
  const SavedAccount({
    required this.uid,
    required this.username,
    this.photoUrl = '',
    this.email = '',
  });
  final String uid;
  final String username;
  final String photoUrl;
  final String email;

  Map<String, String> toMap() => {
    'uid': uid,
    'username': username,
    'photoUrl': photoUrl,
    'email': email,
  };

  static SavedAccount? fromMap(Object? m) {
    if (m is! Map) return null;
    final uid = m['uid'];
    final name = m['username'];
    if (uid is! String || uid.isEmpty || name is! String) return null;
    String s(Object? v) => v is String ? v : '';
    return SavedAccount(
      uid: uid,
      username: name,
      photoUrl: s(m['photoUrl']),
      email: s(m['email']),
    );
  }
}

/// One watched post in the history.
class HistoryEntry {
  const HistoryEntry(this.postId, this.at);
  final String postId;
  final DateTime at;
}

/// Small settings kept on the phone (language, accessibility, screen time, watch history,
/// remembered accounts). Works without [init] too (nothing is saved then), so tests need no setup.
class AppPrefs {
  AppPrefs._();
  static final AppPrefs instance = AppPrefs._();

  SharedPreferences? _p;

  Future<void> init() async {
    try {
      _p = await SharedPreferences.getInstance();
    } catch (_) {
      _p = null;
    }
  }

  // ---- language
  String get language => _p?.getString('lang') ?? 'en';
  set language(String v) => _p?.setString('lang', v);

  // ---- accessibility
  /// The font last picked for chat messages ('' = normal).
  String get chatFont => _p?.getString('chatFont') ?? '';
  set chatFont(String v) => _p?.setString('chatFont', v);

  double get textScale => (_p?.getDouble('textScale') ?? 1.0).clamp(0.8, 1.6);
  set textScale(double v) => _p?.setDouble('textScale', v);
  bool get boldText => _p?.getBool('boldText') ?? false;
  set boldText(bool v) => _p?.setBool('boldText', v);
  bool get reduceMotion => _p?.getBool('reduceMotion') ?? false;
  set reduceMotion(bool v) => _p?.setBool('reduceMotion', v);

  /// 'system', 'light' or 'dark'
  String get themeMode => _p?.getString('themeMode') ?? 'system';
  set themeMode(String v) => _p?.setString('themeMode', v);

  // ---- screen time
  int get dailyLimitMinutes => _p?.getInt('dailyLimit') ?? 0;
  set dailyLimitMinutes(int v) => _p?.setInt('dailyLimit', v);

  static String dayKey(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  int usageSeconds(DateTime day) => _p?.getInt('use_${dayKey(day)}') ?? 0;

  void addUsage(DateTime day, int seconds) {
    final p = _p;
    if (p == null || seconds <= 0) return;
    p.setInt('use_${dayKey(day)}', usageSeconds(day) + seconds);
    // forget what is older than two weeks
    final old = DateTime.now().subtract(const Duration(days: 14));
    for (final k in p.getKeys()) {
      if (k.startsWith('use_') && k.substring(4).compareTo(dayKey(old)) < 0) {
        p.remove(k);
      }
    }
  }

  /// 'uid@day' of the last day this account was counted as active.
  String _activeMem = '';
  String get activeCounted => _p?.getString('activeCounted') ?? _activeMem;
  set activeCounted(String v) {
    _activeMem = v;
    _p?.setString('activeCounted', v);
  }

  /// Word lists from the admin panel (JSON), kept for the next start.
  String _modMem = '';
  String get modWords => _p?.getString('modWords') ?? _modMem;
  set modWords(String v) {
    _modMem = v;
    _p?.setString('modWords', v);
  }

  /// Spam-limit log (JSON: kind -> times).
  String _rateMem = '';
  String get rateLog => _p?.getString('rateLog') ?? _rateMem;
  set rateLog(String v) {
    _rateMem = v;
    _p?.setString('rateLog', v);
  }

  /// The day the daily-limit reminder was last shown.
  String get limitShownDay => _p?.getString('limitShown') ?? '';
  set limitShownDay(String v) => _p?.setString('limitShown', v);

  // ---- watch history
  List<HistoryEntry> get history {
    final raw = _p?.getString('history');
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final e in list)
          if (e is List && e.length == 2 && e[0] is String && e[1] is int)
            HistoryEntry(
              e[0] as String,
              DateTime.fromMillisecondsSinceEpoch(e[1] as int),
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Puts [postId] at the top of the history (once; the newest 150 are kept).
  void addHistory(String postId) {
    final p = _p;
    if (p == null || postId.isEmpty) return;
    final list = [...history.where((e) => e.postId != postId)];
    list.insert(0, HistoryEntry(postId, DateTime.now()));
    final keep = list.take(150);
    p.setString(
      'history',
      jsonEncode([
        for (final e in keep) [e.postId, e.at.millisecondsSinceEpoch],
      ]),
    );
  }

  void removeHistory(String postId) {
    final p = _p;
    if (p == null) return;
    p.setString(
      'history',
      jsonEncode([
        for (final e in history.where((e) => e.postId != postId))
          [e.postId, e.at.millisecondsSinceEpoch],
      ]),
    );
  }

  void clearHistory() => _p?.remove('history');

  // ---- remembered accounts
  List<SavedAccount> get accounts {
    final raw = _p?.getString('accounts');
    if (raw == null) return const [];
    try {
      return [
        for (final e in jsonDecode(raw) as List) ?SavedAccount.fromMap(e),
      ];
    } catch (_) {
      return const [];
    }
  }

  void rememberAccount(SavedAccount a) {
    final p = _p;
    if (p == null) return;
    final list = [...accounts.where((e) => e.uid != a.uid), a];
    p.setString('accounts', jsonEncode([for (final e in list) e.toMap()]));
  }

  void forgetAccount(String uid) {
    final p = _p;
    if (p == null) return;
    p.setString(
      'accounts',
      jsonEncode([
        for (final e in accounts.where((e) => e.uid != uid)) e.toMap(),
      ]),
    );
  }
}
