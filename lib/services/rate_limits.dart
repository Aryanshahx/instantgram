import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';

import '../core/errors.dart';
import 'app_prefs.dart';

/// Limits per phone and account against spam: comments, follows, uploads, copy-paste comments.
class RateLimits {
  RateLimits._();
  static final RateLimits instance = RateLimits._();

  static const int commentsPerHour = 30;
  static const int followsPerMinute = 20;
  static const int uploadsPerDayNew = 10;
  static const int uploadsPerDay = 50;
  static const int sameCommentMax = 2;

  /// Accounts younger than this count as new.
  static const Duration newAccount = Duration(days: 7);

  /// Tests set the clock.
  DateTime Function() now = DateTime.now;

  Map<String, List<int>>? _mem;

  Map<String, List<int>> get _log {
    if (_mem != null) return _mem!;
    final out = <String, List<int>>{};
    try {
      final m = jsonDecode(AppPrefs.instance.rateLog);
      if (m is Map) {
        m.forEach((k, v) {
          if (k is String && v is List) {
            out[k] = [
              for (final x in v)
                if (x is int) x,
            ];
          }
        });
      }
    } catch (_) {}
    return _mem = out;
  }

  void _save() => AppPrefs.instance.rateLog = jsonEncode(_log);

  /// Forgets everything (logout, tests).
  void reset() {
    _mem = {};
    _save();
  }

  /// Counts one [kind] event, or throws when [max] happened within [per] already.
  void _take(String kind, int max, Duration per, String message) {
    final t = now().millisecondsSinceEpoch;
    final from = t - per.inMilliseconds;
    final list = (_log[kind] ?? const <int>[]).where((x) => x > from).toList();
    if (list.length >= max) {
      _log[kind] = list;
      throw RateLimitException(message);
    }
    list.add(t);
    _log[kind] = list;
    _prune();
    _save();
  }

  static int _hash(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ').hashCode;

  /// Before a comment: at most [commentsPerHour], and the same words at most [sameCommentMax]
  /// times an hour.
  void comment(String uid, String text) {
    if (text.trim().isNotEmpty) {
      final key = 'same:$uid:${_hash(text)}';
      final t = now().millisecondsSinceEpoch;
      final recent = (_log[key] ?? const <int>[])
          .where((x) => x > t - const Duration(hours: 1).inMilliseconds)
          .length;
      if (recent >= sameCommentMax) {
        throw const RateLimitException(
          'You already posted that comment. Write something new.',
        );
      }
    }
    _take(
      'comment:$uid',
      commentsPerHour,
      const Duration(hours: 1),
      'You are commenting very fast. Take a short break and try again later.',
    );
    if (text.trim().isNotEmpty) {
      final key = 'same:$uid:${_hash(text)}';
      (_log[key] ??= []).add(now().millisecondsSinceEpoch);
      _prune();
      _save();
    }
  }

  void follow(String uid) => _take(
    'follow:$uid',
    followsPerMinute,
    const Duration(minutes: 1),
    'You are following people very fast. Wait a minute and try again.',
  );

  /// Before a post, clip or moment. [created] = when the account was made (null = unknown).
  void upload(String uid, DateTime? created) {
    final young = created != null && now().difference(created) < newAccount;
    _take(
      'upload:$uid',
      young ? uploadsPerDayNew : uploadsPerDay,
      const Duration(days: 1),
      young
          ? 'New accounts can share $uploadsPerDayNew posts a day. Try again tomorrow.'
          : 'You reached $uploadsPerDay posts today. Try again tomorrow.',
    );
  }

  /// Old copy-paste records are dropped so the saved log stays small.
  void _prune() {
    final cut =
        now().millisecondsSinceEpoch - const Duration(days: 1).inMilliseconds;
    _log.removeWhere((k, v) {
      v.removeWhere((x) => x < cut);
      return v.isEmpty;
    });
  }
}

/// The logged-in account ('' in tests or logged out).
String currentUidOrEmpty() {
  try {
    return FirebaseAuth.instance.currentUser?.uid ?? '';
  } catch (_) {
    return '';
  }
}

/// When the logged-in account was made (null = unknown).
DateTime? accountCreatedAt() {
  try {
    return FirebaseAuth.instance.currentUser?.metadata.creationTime;
  } catch (_) {
    return null;
  }
}

/// Before an upload: throws [RateLimitException] when the daily limit is reached.
void checkUploadLimit() {
  final uid = currentUidOrEmpty();
  if (uid.isNotEmpty) RateLimits.instance.upload(uid, accountCreatedAt());
}
