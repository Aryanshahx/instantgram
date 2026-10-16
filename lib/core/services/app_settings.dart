import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One item in "History" (things you watched on this phone).
class HistoryEntry {
  const HistoryEntry(this.postId, this.isClip, this.at);
  final String postId;
  final bool isClip;
  final DateTime at;

  Map<String, dynamic> toJson() => {
    'id': postId,
    'c': isClip,
    't': at.millisecondsSinceEpoch,
  };

  static HistoryEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    final t = j['t'];
    if (id is! String || t is! int) return null;
    return HistoryEntry(
      id,
      j['c'] == true,
      DateTime.fromMillisecondsSinceEpoch(t),
    );
  }
}

/// Small on-device settings (kept after the app closes).
class AppSettings {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  static const _kAutoScroll = 'clips_auto_scroll';
  static const _kTextScale = 'text_scale';
  static const _kReduceMotion = 'reduce_motion';
  static const _kLanguage = 'language';
  static const _kSeen = 'seen_moments';
  static const _kHistory = 'history';
  static const _kUsage = 'usage_seconds';
  static const _kLimit = 'daily_limit_min';
  static const _kLimitShown = 'daily_limit_shown';
  static const _kViewed = 'viewed_posts';
  static const _kErrors = 'error_log';
  static const maxViewed = 3000;
  static const maxErrors = 30;

  static const maxHistory = 200;
  static const maxSeen = 600;

  /// Clips: go to the next clip automatically when one ends.
  final ValueNotifier<bool> clipsAutoScroll = ValueNotifier(false);

  /// Accessibility: text size (1.0 = normal).
  final ValueNotifier<double> textScale = ValueNotifier(1.0);

  /// Accessibility: fewer animations.
  final ValueNotifier<bool> reduceMotion = ValueNotifier(false);

  /// Chosen language code (also saved on your account).
  final ValueNotifier<String> language = ValueNotifier('en');

  /// Moment ids you have already watched (ring turns grey).
  final ValueNotifier<Set<String>> seenMoments = ValueNotifier(<String>{});

  /// Watched posts/clips (newest first).
  final ValueNotifier<List<HistoryEntry>> history = ValueNotifier(
    const <HistoryEntry>[],
  );

  /// Seconds used per day: {"2026-10-13": 812}
  final ValueNotifier<Map<String, int>> usage = ValueNotifier(const {});

  /// Daily reminder in minutes (0 = off).
  final ValueNotifier<int> dailyLimitMinutes = ValueNotifier(0);

  /// Sound in Discover (videos + music). On by default, not saved.
  final ValueNotifier<bool> feedMuted = ValueNotifier(false);

  /// Posts this account already counted a view for (on this phone).
  final List<String> _viewed = [];
  final Set<String> _viewedSet = {};

  /// Last app errors (newest first) — Settings → About → Error log.
  final ValueNotifier<List<String>> errorLog = ValueNotifier(const <String>[]);

  String _limitShownDay = '';

  bool _loaded = false;
  Future<void>? _loading;

  Future<void> load() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      clipsAutoScroll.value = p.getBool(_kAutoScroll) ?? false;
      textScale.value = (p.getDouble(_kTextScale) ?? 1.0).clamp(0.8, 1.4);
      reduceMotion.value = p.getBool(_kReduceMotion) ?? false;
      language.value = p.getString(_kLanguage) ?? 'en';
      languageSaved = p.containsKey(_kLanguage);
      seenMoments.value = (p.getStringList(_kSeen) ?? const []).toSet();
      dailyLimitMinutes.value = p.getInt(_kLimit) ?? 0;
      _limitShownDay = p.getString(_kLimitShown) ?? '';
      final viewed = p.getStringList(_kViewed) ?? const [];
      _viewed
        ..clear()
        ..addAll(viewed);
      _viewedSet
        ..clear()
        ..addAll(viewed);
      errorLog.value = p.getStringList(_kErrors) ?? const [];
      final h = p.getString(_kHistory);
      if (h != null) {
        final list = (jsonDecode(h) as List)
            .map(HistoryEntry.fromJson)
            .whereType<HistoryEntry>()
            .toList();
        history.value = list;
      }
      final u = p.getString(_kUsage);
      if (u != null) {
        final m = (jsonDecode(u) as Map).map(
          (k, v) => MapEntry(k.toString(), v is num ? v.toInt() : 0),
        );
        usage.value = m;
      }
    } catch (_) {
      // settings are optional — keep defaults
    }
    _loaded = true;
  }

  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  Future<void> setClipsAutoScroll(bool on) async {
    clipsAutoScroll.value = on;
    await (await _prefs())?.setBool(_kAutoScroll, on);
  }

  Future<void> setTextScale(double v) async {
    textScale.value = v.clamp(0.8, 1.4);
    await (await _prefs())?.setDouble(_kTextScale, textScale.value);
  }

  Future<void> setReduceMotion(bool on) async {
    reduceMotion.value = on;
    await (await _prefs())?.setBool(_kReduceMotion, on);
  }

  /// v0.20: false = never chosen on this phone (logged in on a new phone):
  /// the language from your profile is used then.
  bool languageSaved = false;

  Future<void> setLanguage(String code) async {
    language.value = code;
    languageSaved = true;
    await (await _prefs())?.setString(_kLanguage, code);
  }

  // ---------------- Moments seen ----------------

  bool isSeen(String momentId) => seenMoments.value.contains(momentId);

  Future<void> markSeen(String momentId) async {
    if (seenMoments.value.contains(momentId)) return;
    final list = [...seenMoments.value, momentId];
    final trimmed = list.length > maxSeen
        ? list.sublist(list.length - maxSeen)
        : list;
    seenMoments.value = trimmed.toSet();
    await (await _prefs())?.setStringList(_kSeen, trimmed);
  }

  // ---------------- Views (one per account) ----------------

  bool hasViewed(String postId) => _viewedSet.contains(postId);

  Future<void> markViewed(String postId) async {
    if (!_viewedSet.add(postId)) return;
    _viewed.add(postId);
    while (_viewed.length > maxViewed) {
      _viewedSet.remove(_viewed.removeAt(0));
    }
    await (await _prefs())?.setStringList(_kViewed, _viewed);
  }

  // ---------------- Error log ----------------

  Future<void> logError(String text) async {
    final t = text.length > 1500 ? '${text.substring(0, 1500)}…' : text;
    final line = '${DateTime.now().toIso8601String().substring(0, 19)}  $t';
    final list = [line, ...errorLog.value];
    errorLog.value = list.length > maxErrors
        ? list.sublist(0, maxErrors)
        : list;
    await (await _prefs())?.setStringList(_kErrors, errorLog.value);
  }

  Future<void> clearErrors() async {
    errorLog.value = const [];
    await (await _prefs())?.remove(_kErrors);
  }

  // ---------------- History ----------------

  Future<void> addHistory(String postId, {required bool isClip}) async {
    final list = [
      HistoryEntry(postId, isClip, DateTime.now()),
      ...history.value.where((e) => e.postId != postId),
    ];
    history.value = list.length > maxHistory
        ? list.sublist(0, maxHistory)
        : list;
    await _saveHistory();
  }

  Future<void> removeHistory(String postId) async {
    history.value = history.value.where((e) => e.postId != postId).toList();
    await _saveHistory();
  }

  Future<void> clearHistory() async {
    history.value = const [];
    await _saveHistory();
  }

  Future<void> _saveHistory() async {
    await (await _prefs())?.setString(
      _kHistory,
      jsonEncode(history.value.map((e) => e.toJson()).toList()),
    );
  }

  // ---------------- Time ----------------

  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  int secondsOn(DateTime day) => usage.value[dayKey(day)] ?? 0;

  /// Adds used time to today. Keeps the last 30 days.
  Future<void> addUsage(int seconds, {DateTime? now}) async {
    if (seconds <= 0) return;
    final today = dayKey(now ?? DateTime.now());
    final m = Map<String, int>.from(usage.value);
    m[today] = (m[today] ?? 0) + seconds;
    final keys = m.keys.toList()..sort();
    while (keys.length > 30) {
      m.remove(keys.removeAt(0));
    }
    usage.value = m;
    await (await _prefs())?.setString(_kUsage, jsonEncode(m));
  }

  Future<void> setDailyLimit(int minutes) async {
    dailyLimitMinutes.value = minutes;
    await (await _prefs())?.setInt(_kLimit, minutes);
  }

  /// True once per day when today's time passes the limit.
  bool shouldRemind({DateTime? now}) {
    final limit = dailyLimitMinutes.value;
    if (limit <= 0) return false;
    final day = dayKey(now ?? DateTime.now());
    if (_limitShownDay == day) return false;
    return (usage.value[day] ?? 0) >= limit * 60;
  }

  Future<void> markReminded({DateTime? now}) async {
    _limitShownDay = dayKey(now ?? DateTime.now());
    await (await _prefs())?.setString(_kLimitShown, _limitShownDay);
  }
}
