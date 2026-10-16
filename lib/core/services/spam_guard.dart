import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Too many in a short time (the text is shown to the user).
class SpamLimitException implements Exception {
  const SpamLimitException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// v0.20 Hyper Intelligence: spam limits.
///  * New accounts (first 24 hours): max 20 comments an hour, 50 follows
///    an hour and 10 posts / clips a day.
///  * Everyone: max 60 comments an hour and 200 follows a day.
///  * The same comment pasted again and again is stopped (3 an hour).
///  * Accounts younger than 7 days can't put links in comments.
class SpamGuard {
  SpamGuard._();
  static final SpamGuard instance = SpamGuard._();

  static const int newCommentsPerHour = 20;
  static const int newFollowsPerHour = 50;
  static const int newPostsPerDay = 10;
  static const int commentsPerHour = 60;
  static const int followsPerDay = 200;
  static const int sameCommentPerHour = 3;

  static const _hour = 3600000;
  static const _day = 24 * _hour;

  @visibleForTesting
  static int Function()? debugNow;

  /// Tests: when the account was made.
  @visibleForTesting
  static DateTime? debugCreated;

  int get _now => (debugNow ?? () => DateTime.now().millisecondsSinceEpoch)();

  Duration get accountAge {
    final c =
        debugCreated ?? FirebaseAuth.instance.currentUser?.metadata.creationTime;
    if (c == null) return const Duration(days: 365);
    return Duration(milliseconds: _now - c.millisecondsSinceEpoch);
  }

  bool get isNew => accountAge < const Duration(hours: 24);

  final Map<String, List<int>> _log = {};
  final List<(String, int)> _texts = [];
  bool _loaded = false;

  @visibleForTesting
  void debugReset() {
    _log.clear();
    _texts.clear();
    _loaded = true;
  }

  /// Saved counts (so closing the app doesn't reset them).
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('spam_guard');
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      for (final e in m.entries) {
        if (e.key == 'texts') continue;
        _log[e.key] = [
          for (final t in (e.value as List? ?? const [])) (t as num).toInt(),
        ];
      }
      for (final t in (m['texts'] as List? ?? const [])) {
        final l = t as List;
        _texts.add(('${l[0]}', (l[1] as num).toInt()));
      }
    } catch (_) {}
  }

  void _save() {
    final data = jsonEncode({
      ..._log,
      'texts': [
        for (final t in _texts) [t.$1, t.$2],
      ],
    });
    unawaited(
      SharedPreferences.getInstance()
          .then((p) => p.setString('spam_guard', data))
          .catchError((Object _) => false),
    );
  }

  int _count(String kind, int within) {
    final now = _now;
    final l = _log[kind] ?? const [];
    return l.where((t) => now - t < within).length;
  }

  void _add(String kind) {
    final now = _now;
    final l = (_log[kind] ?? <int>[])
      ..removeWhere((t) => now - t >= _day)
      ..add(now);
    _log[kind] = l;
    _save();
  }

  static String _norm(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  static final RegExp _link = RegExp(
    r'(https?://|www\.)\S+|\b[\w-]+\.(com|in|net|org|xyz|io|me|co|ly|link|site|shop|online|app)\b',
    caseSensitive: false,
  );

  static bool hasLink(String text) => _link.hasMatch(text);

  /// null = OK, else the reason it is stopped.
  String? checkComment(String text) {
    if (hasLink(text) && accountAge < const Duration(days: 7)) {
      return 'New accounts can add links in comments after 7 days.';
    }
    final perHour = isNew ? newCommentsPerHour : commentsPerHour;
    if (_count('comment', _hour) >= perHour) {
      return "You're commenting too fast. Please wait a little.";
    }
    final n = _norm(text);
    if (n.length >= 8) {
      final now = _now;
      final same = _texts.where((t) => t.$1 == n && now - t.$2 < _hour);
      if (same.length >= sameCommentPerHour) {
        return 'You already posted this comment many times.';
      }
    }
    return null;
  }

  void recordComment(String text) {
    _add('comment');
    final n = _norm(text);
    if (n.length >= 8) {
      final now = _now;
      _texts
        ..removeWhere((t) => now - t.$2 >= _hour)
        ..add((n.length > 200 ? n.substring(0, 200) : n, now));
      _save();
    }
  }

  String? checkFollow() {
    if (isNew && _count('follow', _hour) >= newFollowsPerHour) {
      return "You're following too fast. Please try again later.";
    }
    if (_count('follow', _day) >= followsPerDay) {
      return 'You followed a lot of people today. Please try again tomorrow.';
    }
    return null;
  }

  void recordFollow() => _add('follow');

  String? checkPost() {
    if (isNew && _count('post', _day) >= newPostsPerDay) {
      return 'New accounts can share 10 posts or clips a day. '
          'Please try again tomorrow.';
    }
    return null;
  }

  void recordPost() => _add('post');

  /// Throws [SpamLimitException] when [reason] is not null.
  static void stopIf(String? reason) {
    if (reason != null) throw SpamLimitException(reason);
  }
}
