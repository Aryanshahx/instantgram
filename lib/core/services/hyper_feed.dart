import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/models/post.dart';
import 'content_filter.dart';
import 'hyper_intelligence.dart';

/// Which list is being ordered.
enum FeedMode {
  /// Home feed: posts + clips, mixing rules for both.
  discover,

  /// Clips tab.
  clips,

  /// Explore grid (interests + quality + new creators).
  explore,
}

/// v0.19 Hyper Intelligence - the feed algorithm (runs on the phone).
///
/// Learns what you like (people, hashtags, clips vs photos) from likes,
/// comments, saves, shares, reposts, full watches, quick skips, profile
/// visits and chats. Older actions count less (half after 14 days).
///
/// score = (3 x Closeness + 2 x Interest + 2 x Quality + 2 x Freshness
///          + 1 x Following) x Safety
/// then the mixing rules (no more than 2 in a row from one person, new
/// posts from people you follow in the first 10, 1 in 5 from someone new,
/// nothing you saw today at the top, max 3 clips / photos in a row).
class HyperFeed with WidgetsBindingObserver {
  HyperFeed._();
  static final HyperFeed instance = HyperFeed._();

  static const _day = 24 * 60 * 60 * 1000;
  static const _halfLife = 14 * _day;

  /// Changes when "Not interested" hides something (lists rebuild).
  final ValueNotifier<int> version = ValueNotifier(0);

  String _uid = '';

  // name -> [weight, when (ms)]
  final Map<String, List<num>> _people = {};
  final Map<String, List<num>> _tags = {};
  List<num> _clipW = [0, 0];
  List<num> _photoW = [0, 0];
  final Map<String, int> _notPeople = {};
  final Map<String, int> _notTags = {};
  final Map<String, int> _seen = {};
  final Map<String, int> _hidden = {};

  // once per app run
  final Set<String> _watchDone = {};
  final Set<String> _skipDone = {};

  /// Tests: fixed time.
  @visibleForTesting
  static int Function()? debugNow;
  int get _now => (debugNow ?? () => DateTime.now().millisecondsSinceEpoch)();

  String get _me => ContentFilter.instance.uid;

  /// Online copy (only you can read it). Set by the main screen.
  Future<void> Function(String json)? uploader;
  Future<String?> Function()? downloader;

  // ------------------------------------------------------------ storage

  String get _key => 'hyper_feed_$_uid';

  /// Main screen start: loads what was learned (phone, else online copy).
  Future<void> start(String uid) async {
    if (_uid == uid && _loaded) return;
    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
    }
    _uid = uid;
    _clear();
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        load(raw);
      } else {
        final online = await downloader?.call();
        if (online != null && online.isNotEmpty) load(online);
      }
    } catch (e) {
      debugPrint('HyperFeed load: $e');
    }
    _loaded = true;
    version.value++;
  }

  bool _loaded = false;
  bool _observing = false;

  /// App goes to the background -> save what was learned.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      if (_dirty > 0) unawaited(save());
    }
  }

  void _clear() {
    _people.clear();
    _tags.clear();
    _clipW = [0, 0];
    _photoW = [0, 0];
    _notPeople.clear();
    _notTags.clear();
    _seen.clear();
    _hidden.clear();
    _orders.clear();
  }

  @visibleForTesting
  void debugReset() {
    _clear();
    _watchDone.clear();
    _skipDone.clear();
    _uid = '';
    _loaded = false;
    _dirty = 0;
  }

  Map<String, List<num>> _readMap(Object? v) {
    final out = <String, List<num>>{};
    if (v is Map) {
      v.forEach((k, e) {
        if (e is List && e.length == 2 && e[0] is num && e[1] is num) {
          out['$k'] = [e[0] as num, e[1] as num];
        }
      });
    }
    return out;
  }

  Map<String, int> _readTimes(Object? v) {
    final out = <String, int>{};
    if (v is Map) {
      v.forEach((k, e) {
        if (e is num) out['$k'] = e.toInt();
      });
    }
    return out;
  }

  List<num> _readPair(Object? v) =>
      v is List && v.length == 2 && v[0] is num && v[1] is num
      ? [v[0] as num, v[1] as num]
      : [0, 0];

  /// Reads a saved copy.
  void load(String raw) {
    final d = jsonDecode(raw);
    if (d is! Map) return;
    _people
      ..clear()
      ..addAll(_readMap(d['p']));
    _tags
      ..clear()
      ..addAll(_readMap(d['t']));
    _clipW = _readPair(d['clip']);
    _photoW = _readPair(d['photo']);
    _notPeople
      ..clear()
      ..addAll(_readTimes(d['np']));
    _notTags
      ..clear()
      ..addAll(_readTimes(d['nt']));
    _seen
      ..clear()
      ..addAll(_readTimes(d['seen']));
    _hidden
      ..clear()
      ..addAll(_readTimes(d['hide']));
    _prune();
  }

  /// Everything as JSON ([online] = the small copy: top 30, no seen list).
  String dump({bool online = false}) {
    Map<String, List<num>> top(Map<String, List<num>> m) {
      if (!online) return m;
      final now = _now;
      final list = m.entries.toList()
        ..sort((a, b) => _val(b.value, now).compareTo(_val(a.value, now)));
      return {for (final e in list.take(30)) e.key: e.value};
    }

    return jsonEncode({
      'v': 1,
      'p': top(_people),
      't': top(_tags),
      'clip': _clipW,
      'photo': _photoW,
      'np': _notPeople,
      'nt': _notTags,
      if (!online) 'seen': _seen,
      if (!online) 'hide': _hidden,
    });
  }

  int _lastUpload = 0;
  int _dirty = 0;

  /// Saved every 8 changes and when the app goes to the background (no
  /// timers).
  void _changed() {
    if (++_dirty >= 8) unawaited(save());
  }

  /// Saves on the phone (and online at most every 10 minutes).
  Future<void> save() async {
    _dirty = 0;
    if (_uid.isEmpty) return;
    _prune();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, dump());
    } catch (_) {}
    final now = _now;
    final up = uploader;
    if (up != null && now - _lastUpload > 10 * 60 * 1000) {
      _lastUpload = now;
      try {
        await up(dump(online: true));
      } catch (e) {
        debugPrint('HyperFeed upload: $e');
      }
    }
  }

  void _prune() {
    final now = _now;
    void cap(Map<String, List<num>> m, int max) {
      m.removeWhere((k, v) => _val(v, now).abs() < 0.05);
      if (m.length <= max) return;
      final list = m.entries.toList()
        ..sort((a, b) => _val(b.value, now).compareTo(_val(a.value, now)));
      m
        ..clear()
        ..addEntries(list.take(max));
    }

    void old(Map<String, int> m, int days, int max) {
      m.removeWhere((k, t) => now - t > days * _day);
      if (m.length <= max) return;
      final list = m.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      m
        ..clear()
        ..addEntries(list.take(max));
    }

    cap(_people, 200);
    cap(_tags, 200);
    old(_notPeople, 90, 300);
    old(_notTags, 90, 300);
    old(_seen, 30, 3000);
    old(_hidden, 180, 1000);
  }

  // ------------------------------------------------------------ learning

  /// Weight now (older = less: half after 14 days).
  static double _val(List<num> v, int now) {
    final age = (now - v[1]).clamp(0, 1 << 52);
    return (v[0] * math.pow(0.5, age / _halfLife)).toDouble();
  }

  void _add(Map<String, List<num>> m, String k, double w) {
    if (k.isEmpty) return;
    final now = _now;
    final old = m[k];
    m[k] = [(old == null ? 0 : _val(old, now)) + w, now];
  }

  List<num> _addPair(List<num> v, double w) {
    final now = _now;
    return [_val(v, now) + w, now];
  }

  static List<String> tagsOf(Post p) {
    final out = <String>{};
    for (final m in RegExp(
      r'#([\p{L}\p{M}\p{N}_]{1,50})',
      unicode: true,
    ).allMatches(p.caption)) {
      out.add(m.group(1)!.toLowerCase());
      if (out.length >= 30) break;
    }
    return out.toList();
  }

  /// Something you did with a post (+ = liked it, - = didn't).
  void learnPost(Post p, double w) {
    if (p.authorId == _me && _me.isNotEmpty) return;
    _add(_people, p.authorId, w);
    for (final t in tagsOf(p)) {
      _add(_tags, t, w * 0.6);
    }
    if (p.isClip) {
      _clipW = _addPair(_clipW, w);
    } else {
      _photoW = _addPair(_photoW, w);
    }
    _changed();
  }

  /// Profile visits, chats.
  void learnPerson(String uid, double w) {
    if (uid.isEmpty || uid == _me) return;
    _add(_people, uid, w);
    _changed();
  }

  void liked(Post p, bool on) => learnPost(p, on ? 1 : -1);
  void saved(Post p, bool on) => learnPost(p, on ? 2 : -1);
  void reposted(Post p, bool on) => learnPost(p, on ? 2 : -1);
  void commented(Post p) => learnPost(p, 2);
  void shared(Post p) => learnPost(p, 3);
  void visitedProfile(String uid) => learnPerson(uid, 0.5);
  void chatted(String uid) => learnPerson(uid, 1);

  /// Watching: to the end = strong yes; gone in under 2 s = small no.
  void watched(Post p, {required int watchMs, required bool completed}) {
    if (completed) {
      if (_watchDone.add(p.id)) {
        // watched it again (seen on an earlier day too) counts more
        learnPost(p, _seenBeforeToday(p.id) ? 3 : 2);
      }
      return;
    }
    if (p.isClip && watchMs < 2000 && _skipDone.add(p.id)) {
      learnPost(p, -0.5);
    }
  }

  /// "Not interested": hides this post, fewer from this person / tags.
  void notInterested(Post p) {
    final now = _now;
    _hidden[p.id] = now;
    if (p.authorId.isNotEmpty) _notPeople[p.authorId] = now;
    for (final t in tagsOf(p)) {
      _notTags[t] = now;
    }
    learnPost(p, -2);
    version.value++;
    unawaited(save());
  }

  bool isHidden(String postId) => _hidden.containsKey(postId);

  /// It was on screen.
  void markSeen(Post p) {
    _seen[p.id] = _now;
    _changed();
  }

  int _startOfToday(int now) {
    final d = DateTime.fromMillisecondsSinceEpoch(now);
    return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
  }

  bool seenToday(String id) {
    final t = _seen[id];
    return t != null && t >= _startOfToday(_now);
  }

  bool _seenBeforeToday(String id) {
    final t = _seen[id];
    return t != null && t < _startOfToday(_now);
  }

  /// Top hashtags (for "posts like the ones you like").
  List<String> topTags([int n = 3]) {
    final now = _now;
    final list =
        _tags.entries
            .where(
              (e) => _val(e.value, now) > 0.5 && !_notTags.containsKey(e.key),
            )
            .toList()
          ..sort((a, b) => _val(b.value, now).compareTo(_val(a.value, now)));
    return [for (final e in list.take(n)) e.key];
  }

  // ------------------------------------------------------------ scoring

  /// 0..1 how close you are to [uid].
  double closeness(String uid) {
    if (uid == _me && uid.isNotEmpty) return 0.6;
    final v = _people[uid];
    if (v == null) return 0;
    final c = math.max(0.0, _val(v, _now));
    return c / (c + 5);
  }

  /// 0..1 how well the post matches what you like.
  double interest(Post p) {
    final now = _now;
    var s = 0.0;
    for (final t in tagsOf(p)) {
      final v = _tags[t];
      if (v != null) s += math.max(0.0, _val(v, now));
    }
    final tagPart = s / (s + 3);
    final c = math.max(0.0, _val(_clipW, now));
    final ph = math.max(0.0, _val(_photoW, now));
    final typePart = (p.isClip ? c : ph) / (c + ph + 2);
    return tagPart * 0.7 + typePart * 0.3;
  }

  /// 0..1 do others like it? The +20 stops 1 view + 1 like looking perfect.
  static double quality(Post p) {
    final r =
        (p.likesCount +
            2 * p.commentsCount +
            3 * p.sharesCount +
            3 * p.savesCount +
            2 * p.repostsCount) /
        (p.viewsCount + 20);
    return r / (r + 0.25);
  }

  /// 0..1 new is better: posts lose half after 24 h, clips after 3 days.
  static double freshness(Post p, int now) {
    final ageH = (now - p.createdAt.millisecondsSinceEpoch) / 3600000;
    if (ageH <= 0) return 1;
    return math.pow(0.5, ageH / (p.isClip ? 72 : 24)).toDouble();
  }

  /// Protection: sensitive, under review, not interested, already seen.
  double safety(Post p) {
    final hi = HyperIntelligence.instance;
    if (_hidden.containsKey(p.id) || hi.hides(p)) return 0;
    var s = 1.0;
    final mine = p.authorId == _me;
    if (!mine) {
      if (p.sensitive) s *= hi.minor ? 0 : 0.2;
      if (p.underReview) s *= 0.5;
      if (_notPeople.containsKey(p.authorId)) s *= 0.1;
      if (tagsOf(p).any(_notTags.containsKey)) s *= 0.4;
    }
    if (_seen.containsKey(p.id)) s *= 0.3;
    return s;
  }

  double score(Post p) {
    final now = _now;
    final following = ContentFilter.instance.isFollowing(p.authorId);
    return (3 * closeness(p.authorId) +
            2 * interest(p) +
            2 * quality(p) +
            2 * freshness(p, now) +
            (following ? 1 : 0)) *
        safety(p);
  }

  bool _isNew(Post p) =>
      p.authorId != _me &&
      !ContentFilter.instance.isFollowing(p.authorId) &&
      closeness(p.authorId) < 0.1;

  bool _mustFirst(Post p, int now) =>
      ContentFilter.instance.isFollowing(p.authorId) &&
      now - p.createdAt.millisecondsSinceEpoch < _day;

  /// v0.20: your own posts and clips are never in your feeds.
  bool _mine(Post p) => _me.isNotEmpty && p.authorId == _me;

  /// Scores + mixing rules. Hidden posts and your own are left out.
  List<Post> rank(List<Post> posts, {FeedMode mode = FeedMode.discover}) {
    final now = _now;
    final scores = <String, double>{};
    final pool = <Post>[];
    final ids = <String>{};
    for (final p in posts) {
      if (_mine(p) || !ids.add(p.id)) continue;
      final s = score(p);
      if (s <= 0 &&
          (_hidden.containsKey(p.id) || HyperIntelligence.instance.hides(p))) {
        continue;
      }
      scores[p.id] = s;
      pool.add(p);
    }
    pool.sort((a, b) {
      final c = scores[b.id]!.compareTo(scores[a.id]!);
      return c != 0 ? c : b.createdAt.compareTo(a.createdAt);
    });
    final discover = mode == FeedMode.discover;
    // new posts from people you follow: always in the first 10
    final must = discover
        ? pool
              .where((p) => _mustFirst(p, now))
              .take(10)
              .map((p) => p.id)
              .toSet()
        : <String>{};
    final out = <Post>[];
    final today = _startOfToday(now);
    bool seenTodayAt(Post p) => (_seen[p.id] ?? 0) >= today;

    var mustLeft = must.length;

    bool ok(Post p, int level) {
      final pos = out.length;
      // (e) must-first posts fill the first 10 when needed
      if (pos < 10 &&
          mustLeft > 0 &&
          10 - pos <= mustLeft &&
          !must.contains(p.id)) {
        return false;
      }
      // (a) max 2 in a row from one person
      if (level < 4 &&
          pos >= 2 &&
          out[pos - 1].authorId == p.authorId &&
          out[pos - 2].authorId == p.authorId) {
        return false;
      }
      // (b) max 3 clips / photos in a row (home feed)
      if (level < 3 &&
          discover &&
          pos >= 3 &&
          out.sublist(pos - 3).every((o) => o.isClip == p.isClip)) {
        return false;
      }
      // (c) nothing you saw today at the top
      if (level < 2 && pos < 3 && seenTodayAt(p)) return false;
      // (d) 1 in every 5 from someone new
      if (level < 1 &&
          mode != FeedMode.clips &&
          pos % 5 == 4 &&
          !out.sublist(pos - 4).any(_isNew) &&
          !_isNew(p)) {
        return false;
      }
      return true;
    }

    final rest = [...pool];
    while (rest.isNotEmpty) {
      var picked = -1;
      for (var level = 0; level <= 4 && picked < 0; level++) {
        for (var i = 0; i < rest.length; i++) {
          if (ok(rest[i], level)) {
            picked = i;
            break;
          }
        }
      }
      if (picked < 0) picked = 0;
      final p = rest.removeAt(picked);
      if (must.contains(p.id)) mustLeft--;
      out.add(p);
    }
    return out;
  }

  // ------------------------------------------------- steady order per list

  final Map<String, List<String>> _orders = {};

  /// Forget the order of [key] (pull to refresh -> ranked again).
  void reset(String key) => _orders.remove(key);

  /// Ranks [fresh] the first time; after that the order stays (so the
  /// list doesn't jump while you scroll). New posts: from people you
  /// follow (last 24 h) go on top in the home feed, others are placed by
  /// score after the first [protect] posts.
  List<Post> ordered(
    String key,
    List<Post> fresh, {
    FeedMode mode = FeedMode.discover,
    int protect = 4,
  }) {
    final visible = fresh
        .where((p) => !_hidden.containsKey(p.id) && !_mine(p))
        .toList();
    final old = _orders[key];
    if (old == null || old.isEmpty) {
      final r = rank(visible, mode: mode);
      _orders[key] = [for (final p in r) p.id];
      return r;
    }
    final byId = <String, Post>{for (final p in visible) p.id: p};
    final out = <Post>[
      for (final id in old)
        if (byId.containsKey(id)) byId.remove(id)!,
    ];
    if (byId.isNotEmpty) {
      final now = _now;
      final news = rank(byId.values.toList(), mode: mode);
      final top = <Post>[];
      for (final p in news) {
        if (mode == FeedMode.discover && _mustFirst(p, now)) {
          top.add(p);
          continue;
        }
        final s = score(p);
        var at = out.length;
        for (var i = math.min(protect, out.length); i < out.length; i++) {
          if (score(out[i]) < s) {
            at = i;
            break;
          }
        }
        out.insert(at, p);
      }
      out.insertAll(0, top);
    }
    _orders[key] = [for (final p in out) p.id];
    return out;
  }

  /// Home feed: [base] (people you follow + famous) + [extras] (posts with
  /// your top hashtags, newest clips) -> ranked, steady order.
  Stream<List<Post>> discover(
    Stream<List<Post>> base, {
    Future<List<Post>> Function()? extras,
    String key = 'discover',
  }) {
    late final StreamController<List<Post>> c;
    StreamSubscription<List<Post>>? sub;
    List<Post>? last;
    var extra = const <Post>[];
    void emit() {
      final l = last;
      if (l == null || c.isClosed) return;
      final ids = {for (final p in l) p.id};
      final all = [...l, ...extra.where((p) => !ids.contains(p.id))];
      c.add(ordered(key, all, mode: FeedMode.discover));
    }

    c = StreamController<List<Post>>(
      onListen: () {
        sub = base.listen((l) {
          last = l;
          emit();
        }, onError: c.addError);
        if (extras != null) {
          extras()
              .then((e) {
                extra = e;
                emit();
              })
              .catchError((Object e) {
                debugPrint('HyperFeed extras: $e');
              });
        }
      },
      onCancel: () => sub?.cancel(),
    );
    return c.stream;
  }
}
