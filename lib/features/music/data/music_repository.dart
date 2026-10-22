import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/api_client.dart';
import '../../../core/services/content_filter.dart';
import '../../../shared/models/music.dart';
import '../../../shared/models/post.dart';

/// What the server says about AI songs today.
class SongInfo {
  const SongInfo({
    required this.enabled,
    required this.left,
    required this.perDay,
    this.fullCost = 2,
  });
  final bool enabled;
  final int left;
  final int perDay;
  final int fullCost;

  factory SongInfo.fromMap(Map<String, dynamic> m) {
    int i(Object? v, int d) => v is num ? v.toInt() : d;
    return SongInfo(
      enabled: m['enabled'] == true,
      left: i(m['left'], 0),
      perDay: i(m['perDay'], 3),
      fullCost: i(m['fullCost'], 2),
    );
  }
}

/// An Epidemic Sound playlist ("Trending on TikTok", "Happy", ...).
class EsPlaylist {
  const EsPlaylist({required this.id, required this.name, this.cover = ''});
  final String id;
  final String name;
  final String cover;

  static EsPlaylist? fromMap(Object? v) {
    if (v is! Map) return null;
    final id = v['id'];
    final name = v['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    final c = v['cover'];
    return EsPlaylist(id: id, name: name, cover: c is String ? c : '');
  }
}

/// Epidemic songs + playlists for the "Trending" tab.
class EsHome {
  const EsHome(this.tracks, this.playlists);
  final List<MusicTrack> tracks;
  final List<EsPlaylist> playlists;
}

/// Songs: Epidemic Sound (trending + search), "use this audio" and AI
/// songs (Google Lyria, coming soon).
class MusicRepository {
  MusicRepository._();
  static final MusicRepository instance = MusicRepository._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _music =>
      _db.collection('music');

  /// Tests: replace the server call.
  Future<Map<String, dynamic>> Function(
    Map<String, dynamic> body,
    Duration timeout,
  )
  call = (body, timeout) =>
      ApiClient.instance.post('/api/hi', body, timeout: timeout);

  /// Tests: lists without Firestore.
  static Future<List<MusicTrack>> Function()? debugMySongs;
  static Future<List<MusicTrack>> Function()? debugAll;
  static Future<MusicTrack?> Function(String id)? debugTrack;
  static Future<List<Post>> Function(String id)? debugPostsWith;

  List<MusicTrack>? _all;
  DateTime? _allAt;

  /// All audios people can use, most used first (top 500). Kept for
  /// 5 minutes. Single-field order -> no extra Firestore index.
  Future<List<MusicTrack>> all({bool fresh = false}) async {
    final da = debugAll;
    if (da != null) return _visible(await da());
    final at = _allAt;
    final cached = _all;
    if (!fresh &&
        cached != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return cached;
    }
    final s = await _music.orderBy('uses', descending: true).limit(500).get();
    final list = _visible(s.docs.map(MusicTrack.fromDoc));
    _all = list;
    _allAt = DateTime.now();
    return list;
  }

  /// Hidden, removed and blocked people's audios left out.
  List<MusicTrack> _visible(Iterable<MusicTrack> l) {
    final f = ContentFilter.instance;
    return sortAudios(l.where((t) => !f.isBlocked(t.ownerUid)));
  }

  /// Audios whose name or artist (@username) matches [query].
  Future<List<MusicTrack>> search(String query) async =>
      query.trim().isEmpty ? const [] : searchAudios(await all(), query);

  /// Saved audios, newest saved first.
  Future<List<MusicTrack>> saved(List<String> ids) async {
    final want = ids.where((x) => x.isNotEmpty && !x.contains('/')).toList();
    if (want.isEmpty) return const [];
    final byId = <String, MusicTrack>{};
    final dt = debugTrack;
    if (dt != null) {
      for (final id in want) {
        final t = await dt(id);
        if (t != null) byId[id] = t;
      }
    } else {
      for (var i = 0; i < want.length; i += 30) {
        final part = want.sublist(
          i,
          i + 30 > want.length ? want.length : i + 30,
        );
        final s = await _music.where(FieldPath.documentId, whereIn: part).get();
        for (final d in s.docs) {
          byId[d.id] = MusicTrack.fromDoc(d);
        }
      }
    }
    final missingEs = want
        .where((id) => id.startsWith('es_') && !byId.containsKey(id))
        .toList();
    if (missingEs.isNotEmpty) {
      try {
        for (final t in await esTracks(missingEs)) {
          byId[t.id] = t;
        }
      } catch (_) {
        // Epidemic not reachable: show the others
      }
    }
    return [
      for (final id in want.reversed)
        if (byId[id] case final t?)
          if (!t.hidden && (t.url.isNotEmpty || t.isEpidemic)) t,
    ];
  }

  /// Tests.
  void debugReset() {
    _all = null;
    _allAt = null;
    _home = null;
    _homeAt = null;
    _originals.clear();
  }

  // ------------------------------------------------- Epidemic Sound

  static List<MusicTrack> _tracks(Object? v) => [
    if (v is List)
      for (final t in v)
        if (t is Map && t['id'] is String)
          MusicTrack.fromMap(
            t['id'] as String,
            Map<String, dynamic>.from(t)
              ..putIfAbsent('source', () => 'epidemic'),
          ),
  ];

  EsHome? _home;
  DateTime? _homeAt;

  /// Most popular songs + playlists (kept 10 minutes).
  Future<EsHome> esHome({bool fresh = false}) async {
    final at = _homeAt;
    final h = _home;
    if (!fresh &&
        h != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 10)) {
      return h;
    }
    final m = await call(const {'action': 'esHome'}, _short);
    final pl = m['collections'];
    final home = EsHome(
      _tracks(m['tracks']),
      pl is List
          ? pl.map(EsPlaylist.fromMap).whereType<EsPlaylist>().toList()
          : const [],
    );
    _home = home;
    _homeAt = DateTime.now();
    return home;
  }

  Future<List<MusicTrack>> esSearch(String term) async {
    final t = term.trim();
    if (t.isEmpty) return const [];
    return _tracks(
      (await call({'action': 'esSearch', 'term': t}, _short))['tracks'],
    );
  }

  Future<List<MusicTrack>> esPlaylist(String id) async => _tracks(
    (await call({'action': 'esCollection', 'id': id}, _short))['tracks'],
  );

  final Map<String, (String, DateTime)> _previews = {};

  /// Short-lived link to listen before using the song (kept 20 minutes).
  Future<String> esPreview(String esId) async {
    final c = _previews[esId];
    if (c != null && DateTime.now().difference(c.$2).inMinutes < 20) {
      return c.$1;
    }
    final u = (await call({'action': 'esPreview', 'id': esId}, _short))['url'];
    if (u is! String || u.isEmpty) throw const ApiException('No preview');
    if (_previews.length > 200) _previews.clear();
    _previews[esId] = (u, DateTime.now());
    return u;
  }

  /// The song saved in our storage (download once for everyone).
  Future<MusicTrack> esUse(MusicTrack t) async {
    final m = await call({
      'action': 'esUse',
      'id': t.esId,
    }, const Duration(seconds: 60));
    final id = m['id'] is String ? m['id'] as String : '';
    final track = MusicTrack.fromMap(id, m);
    if (id.isEmpty || track.url.isEmpty) {
      throw const ApiException('Could not get this song');
    }
    return track;
  }

  /// Epidemic songs by id (saved songs nobody used yet).
  Future<List<MusicTrack>> esTracks(List<String> ids) async {
    if (ids.isEmpty) return const [];
    return _tracks(
      (await call({'action': 'esTracks', 'ids': ids}, _short))['tracks'],
    );
  }

  /// My AI songs (newest first).
  Future<List<MusicTrack>> mySongs() async {
    final dm = debugMySongs;
    if (dm != null) return dm();
    final me = ContentFilter.instance.uid;
    if (me.isEmpty) return const [];
    final s = await _music.where('ownerUid', isEqualTo: me).limit(100).get();
    final list =
        s.docs
            .map(MusicTrack.fromDoc)
            .where((t) => t.isAi && t.url.isNotEmpty)
            .toList()
          ..sort(
            (a, b) => (b.createdAt?.millisecondsSinceEpoch ?? 0).compareTo(
              a.createdAt?.millisecondsSinceEpoch ?? 0,
            ),
          );
    return list;
  }

  final Map<String, String> _originals = {};

  /// v0.0.1: the "Original audio" page of [post] (its id). Older videos
  /// get it now (the server makes it from the video's sound).
  Future<String> originalOf(Post post) async {
    if (post.musicId.isNotEmpty) return post.musicId;
    final known = _originals[post.id];
    if (known != null) return known;
    final id = _str(
      (await call({'action': 'origAudio', 'postId': post.id}, _short))['id'],
    );
    if (id.isEmpty) throw const ApiException('Could not open this audio');
    _originals[post.id] = id;
    return id;
  }

  static String _str(Object? v) => v is String ? v : '';

  Future<MusicTrack?> track(String id) async {
    if (id.isEmpty || id.contains('/')) return null;
    final dt = debugTrack;
    if (dt != null) return dt(id);
    final d = await _music.doc(id).get();
    return d.exists ? MusicTrack.fromDoc(d) : null;
  }

  /// Posts and clips with this song (newest first).
  Future<List<Post>> postsWith(String musicId, {int limit = 120}) async {
    if (musicId.isEmpty) return const [];
    final dp = debugPostsWith;
    if (dp != null) return dp(musicId);
    final s = await _db
        .collection('posts')
        .where('musicId', isEqualTo: musicId)
        .limit(limit)
        .get();
    final filter = ContentFilter.instance;
    return s.docs.map(Post.fromDoc).where(filter.canSeeInFeeds).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<SongInfo> songInfo() async =>
      SongInfo.fromMap(await call(const {'action': 'songInfo'}, _short));

  /// Makes an AI song (takes up to ~2 minutes). Throws [ApiException]
  /// with a friendly message (limit reached, idea not allowed, ...).
  Future<(MusicTrack, SongInfo)> makeSong({
    required String prompt,
    bool full = false,
    bool instrumental = false,
  }) async {
    final m = await call({
      'action': 'song',
      'prompt': prompt.trim(),
      'full': full,
      'instrumental': instrumental,
    }, const Duration(minutes: 5));
    final id = m['id'] is String ? m['id'] as String : '';
    if (id.isEmpty) throw const ApiException('No song came back');
    return (
      MusicTrack.fromMap(id, m),
      SongInfo.fromMap({...m, 'enabled': true}),
    );
  }

  static const Duration _short = Duration(seconds: 20);
}
