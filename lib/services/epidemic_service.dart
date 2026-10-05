import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../core/errors.dart';
import '../core/media_url.dart';
import '../models/music.dart';

/// One page of Epidemic Sound search results.
class MusicPage {
  const MusicPage(this.tracks, this.hasMore);
  final List<MusicTrack> tracks;
  final bool hasMore;
}

/// Epidemic Sound music, reached through the media service (the Epidemic key stays on the
/// server; the app only sends the user's own login).
class EpidemicService {
  EpidemicService._();
  static final EpidemicService instance = EpidemicService._();

  /// Tests replace this to answer without a network.
  Future<Map<String, dynamic>> Function(Map<String, dynamic> request)? backend;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  final Map<String, ({String url, DateTime at})> _urls = {};

  Future<Map<String, dynamic>> _call(Map<String, dynamic> body) async {
    final b = backend;
    if (b != null) return b(body);
    if (!mediaServerConfigured) {
      throw const MediaException('The media service address is not set.');
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw const MediaException('Please log in again.');
    final token = await user.getIdToken() ?? '';
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '$mediaApiBase/music',
        data: body,
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      return res.data ?? const <String, dynamic>{};
    } on DioException catch (e) {
      final data = e.response?.data;
      final detail = data is Map && data['detail'] is String
          ? data['detail'] as String
          : null;
      throw MediaException(
        detail ?? 'Could not reach the audio service. Check your connection.',
      );
    }
  }

  /// Epidemic Sound answers 400 to a search without a word, so the first list (nothing typed
  /// yet) is the catalogue's best match for this word.
  static const String defaultTerm = 'popular';

  Future<MusicPage> search(String term, {int offset = 0}) async {
    final r = await _call({
      'op': 'search',
      'term': term.trim().isEmpty ? defaultTerm : term.trim(),
      'offset': offset,
      'limit': 30,
    });
    final list = r['tracks'];
    final out = <MusicTrack>[];
    if (list is List) {
      for (final e in list) {
        if (e is! Map) continue;
        final id = e['id'];
        if (id is! String || id.isEmpty) continue;
        final t = MusicTrack.epidemic(
          uuid: id,
          title: e['title'] is String ? e['title'] as String : '',
          artist: e['artist'] is String ? e['artist'] as String : '',
          seconds: e['seconds'] is num ? (e['seconds'] as num).toInt() : 0,
          bpm: e['bpm'] is num ? (e['bpm'] as num).toInt() : 0,
          cover: e['cover'] is String ? e['cover'] as String : '',
        );
        rememberMusic(t.id, t.title, t.artist);
        out.add(t);
      }
    }
    return MusicPage(out, r['hasMore'] == true);
  }

  /// A link the player can open (valid for a while; kept for 20 minutes).
  Future<String> audioUrl(MusicTrack t) async {
    final cached = _urls[t.id];
    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 20)) {
      return cached.url;
    }
    final r = await _call({'op': 'url', 'id': t.remoteId});
    final url = r['url'];
    if (url is! String || url.isEmpty) {
      throw const MediaException('The audio service sent no audio link.');
    }
    _urls[t.id] = (url: url, at: DateTime.now());
    return url;
  }
}
