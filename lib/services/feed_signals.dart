import 'dart:convert';
import 'dart:math' as math;

import '../core/post_authors.dart';
import 'app_prefs.dart';
import 'safety_service.dart';

/// What I did that shows I care about an account.
enum Signal {
  like(3),
  superHeart(5),
  comment(5),
  share(4),
  save(3),
  profileVisit(2),
  message(2),
  watchedFully(1),
  skipped(-0.5);

  const Signal(this.points);
  final double points;
}

/// How close I am to each account, kept on the phone (nothing is uploaded). Points fade
/// by half every two weeks.
class Closeness {
  Closeness._();
  static final Closeness instance = Closeness._();

  static const Duration halfLife = Duration(days: 14);
  static const int maxAccounts = 300;

  /// Tests set the clock.
  DateTime Function() now = DateTime.now;

  Map<String, (double, int)>? _cache;
  String _owner = '';

  Map<String, (double, int)> get _all {
    final me = SafetyService.instance.me;
    final c = _cache;
    if (c != null && me == _owner) return c;
    _owner = me;
    final out = <String, (double, int)>{};
    try {
      final m = jsonDecode(AppPrefs.instance.feedData('closeness', me));
      if (m is Map) {
        m.forEach((k, v) {
          if (k is String && v is List && v.length == 2) {
            final s = v[0], t = v[1];
            if (s is num && t is int) out[k] = (s.toDouble(), t);
          }
        });
      }
    } catch (_) {}
    return _cache = out;
  }

  void _save() {
    final all = _all;
    if (all.length > maxAccounts) {
      final keep = all.keys.toList()
        ..sort((a, b) => scoreOf(b).compareTo(scoreOf(a)));
      for (final k in keep.skip(maxAccounts)) {
        all.remove(k);
      }
    }
    AppPrefs.instance.setFeedData(
      'closeness',
      _owner,
      jsonEncode({
        for (final e in all.entries)
          e.key: [double.parse(e.value.$1.toStringAsFixed(2)), e.value.$2],
      }),
    );
  }

  double _decayed((double, int) v) {
    final age = now().millisecondsSinceEpoch - v.$2;
    if (age <= 0) return v.$1;
    return v.$1 * math.pow(0.5, age / halfLife.inMilliseconds);
  }

  /// Points for [uid] right now (0 = no contact).
  double scoreOf(String uid) {
    final v = _all[uid];
    return v == null ? 0 : _decayed(v);
  }

  void bump(String uid, Signal s) {
    if (uid.isEmpty || uid == SafetyService.instance.me) return;
    final next = math.max(0.0, scoreOf(uid) + s.points);
    _all[uid] = (next, now().millisecondsSinceEpoch);
    _save();
  }

  /// For likes, saves and shares, where only the post id is known.
  void bumpPost(String postId, Signal s) => bump(authorOf(postId), s);

  /// Accounts I follow, closest first (Home > Following asks for 30 of them).
  List<String> closest(Iterable<String> uids, {int max = 30}) {
    final l = uids.toList()..sort((a, b) => scoreOf(b).compareTo(scoreOf(a)));
    return l.take(max).toList();
  }

  void clear() {
    _cache = {};
    _owner = SafetyService.instance.me;
    AppPrefs.instance.setFeedData('closeness', _owner, '');
  }

  /// Tests: forget what was loaded.
  void reload() => _cache = null;
}

/// Posts I scrolled past and clips I watched (how much), kept on the phone so the feeds
/// show new things first.
class WatchLog {
  WatchLog._();
  static final WatchLog instance = WatchLog._();

  static const int maxItems = 600;

  DateTime Function() now = DateTime.now;

  Map<String, (int, int)>? _cache;
  String _owner = '';
  bool _dirty = false;

  Map<String, (int, int)> get _all {
    final me = SafetyService.instance.me;
    final c = _cache;
    if (c != null && me == _owner) return c;
    _owner = me;
    final out = <String, (int, int)>{};
    try {
      final m = jsonDecode(AppPrefs.instance.feedData('seenLog', me));
      if (m is Map) {
        m.forEach((k, v) {
          if (k is String && v is List && v.length == 2) {
            final t = v[0], p = v[1];
            if (t is int && p is int) out[k] = (t, p);
          }
        });
      }
    } catch (_) {}
    return _cache = out;
  }

  void _save() {
    final all = _all;
    if (all.length > maxItems) {
      final keys = all.keys.toList()
        ..sort((a, b) => all[a]!.$1.compareTo(all[b]!.$1));
      for (final k in keys.take(all.length - maxItems)) {
        all.remove(k);
      }
    }
    AppPrefs.instance.setFeedData(
      'seenLog',
      _owner,
      jsonEncode({
        for (final e in all.entries) e.key: [e.value.$1, e.value.$2],
      }),
    );
    _dirty = false;
  }

  /// A post went by in a feed (saved in batches).
  void markSeen(String id) {
    if (id.isEmpty || _all.containsKey(id)) return;
    _all[id] = (now().millisecondsSinceEpoch, 0);
    _dirty = true;
    if (_all.length % 10 == 0) _save();
  }

  /// A clip was left after [watched] of its [length]. Watching to the end brings its
  /// author closer, skipping it in the first two seconds a little further away.
  void watched(String id, String authorId, Duration watched, Duration length) {
    if (id.isEmpty) return;
    final total = length.inMilliseconds <= 0 ? 1 : length.inMilliseconds;
    final pct = (watched.inMilliseconds * 100 / total).round().clamp(0, 999);
    final old = _all[id]?.$2 ?? 0;
    _all[id] = (now().millisecondsSinceEpoch, math.max(old, pct));
    _save();
    if (pct >= 80) {
      Closeness.instance.bump(authorId, Signal.watchedFully);
    } else if (watched < const Duration(seconds: 2)) {
      Closeness.instance.bump(authorId, Signal.skipped);
    }
  }

  void flush() {
    if (_dirty) _save();
  }

  bool seen(String id) => _all.containsKey(id);

  /// Percent of the clip watched (0 = only scrolled past, null = never seen).
  int? percent(String id) => _all[id]?.$2;

  void clear() {
    _cache = {};
    _owner = SafetyService.instance.me;
    AppPrefs.instance.setFeedData('seenLog', _owner, '');
  }

  void reload() => _cache = null;
}
