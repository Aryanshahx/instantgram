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

/// Songs: the music library, AI songs (Google Lyria), "use this audio".
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
  static Future<List<MusicTrack>> Function()? debugLibrary;
  static Future<List<MusicTrack>> Function()? debugMySongs;
  static Future<MusicTrack?> Function(String id)? debugTrack;
  static Future<List<Post>> Function(String id)? debugPostsWith;

  List<MusicTrack>? _library;
  DateTime? _libraryAt;

  /// Library songs (most used first). Kept for 10 minutes.
  /// Single-field query -> no extra Firestore index.
  Future<List<MusicTrack>> library({bool fresh = false}) async {
    final dl = debugLibrary;
    if (dl != null) return sortTracks(await dl());
    final at = _libraryAt;
    if (!fresh &&
        _library != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 10)) {
      return _library!;
    }
    final s = await _music
        .where('source', isEqualTo: MusicTrack.library)
        .limit(500)
        .get();
    _library = sortTracks(s.docs.map(MusicTrack.fromDoc));
    _libraryAt = DateTime.now();
    return _library!;
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
    return (MusicTrack.fromMap(id, m), SongInfo.fromMap({...m, 'enabled': true}));
  }

  static const Duration _short = Duration(seconds: 20);

  /// Tests.
  void debugReset() {
    _library = null;
    _libraryAt = null;
  }
}
