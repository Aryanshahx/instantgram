import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../core/errors.dart';
import '../models/music.dart';
import 'online_music_service.dart' show MusicPage;

/// Songs from Apple: the free, public iTunes Search API (no key, no server of ours). It gives
/// the title, the artist, the cover and a 30 second preview (`previewUrl`) of each song, and
/// Apple's "most played" chart for the trending list. The phone talks to Apple directly.
class ItunesService {
  ItunesService._();
  static final ItunesService instance = ItunesService._();

  /// Which store (country) is asked. Apple answers with the songs of that store.
  static const String country = 'in';

  /// Tests replace this: it gets the full address and returns the decoded JSON (a Map).
  Future<Map<String, dynamic>> Function(String url)? backend;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.plain,
    ),
  );

  /// Forgets the kept chart and preview addresses (tests start from nothing).
  void clearCache() {
    _chart = null;
    _chartAt = DateTime.fromMillisecondsSinceEpoch(0);
    _previews.clear();
  }

  List<MusicTrack>? _chart;
  DateTime _chartAt = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, String> _previews = {};

  Future<Map<String, dynamic>> _get(String url) async {
    final b = backend;
    if (b != null) return b(url);
    try {
      final res = await _dio.get<String>(url);
      final data = jsonDecode(res.data ?? '{}');
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      throw MediaException(
        code == 403 || code == 429
            ? 'Apple is busy right now. Try again in a minute.'
            : 'Could not reach the song service. Check your connection.',
      );
    } on FormatException {
      throw const MediaException('The song service sent an unreadable answer.');
    }
  }

  /// A bigger cover from the 100 pixel address Apple gives.
  static String cover(String url) =>
      url.replaceFirst(RegExp(r'/\d+x\d+bb\.'), '/200x200bb.');

  MusicTrack? _track(Object? e) {
    if (e is! Map) return null;
    final preview = e['previewUrl'];
    final id = e['trackId'] ?? e['id'];
    if (preview is! String || !preview.startsWith('https://')) return null;
    if (id == null || '$id'.isEmpty) return null;
    final art = e['artworkUrl100'];
    final t = MusicTrack.apple(
      trackId: '$id',
      title: e['trackName'] is String ? e['trackName'] as String : '',
      artist: e['artistName'] is String ? e['artistName'] as String : '',
      seconds: 30,
      cover: art is String ? cover(art) : '',
      previewUrl: preview,
    );
    _previews[t.id] = preview;
    rememberMusic(t.id, t.title, t.artist);
    return t;
  }

  /// A search for [term]; nothing typed gives Apple's "most played" songs.
  Future<MusicPage> search(String term, {int offset = 0}) async {
    final q = term.trim();
    if (q.isEmpty) return MusicPage(await _trending(), false, 0);
    const limit = 30;
    final r = await _get(
      'https://itunes.apple.com/search?term=${Uri.encodeQueryComponent(q)}'
      '&media=music&entity=song&limit=$limit&offset=$offset&country=$country',
    );
    final list = r['results'];
    final raw = list is List ? list : const [];
    final out = <MusicTrack>[];
    for (final e in raw) {
      final t = _track(e);
      if (t != null) out.add(t);
    }
    return MusicPage(out, raw.length >= limit, offset + raw.length);
  }

  /// The chart (kept for 30 minutes), with a preview for each song.
  Future<List<MusicTrack>> _trending() async {
    final c = _chart;
    if (c != null && DateTime.now().difference(_chartAt).inMinutes < 30) {
      return c;
    }
    final chart = await _get(
      'https://rss.applemarketingtools.com/api/v2/$country/music/most-played/50/songs.json',
    );
    final feed = chart['feed'];
    final results = feed is Map && feed['results'] is List
        ? feed['results'] as List
        : const [];
    final ids = [
      for (final e in results)
        if (e is Map && e['id'] != null) '${e['id']}',
    ];
    if (ids.isEmpty) return const [];
    // the chart has no previews: ask for them in one request, keep the chart's order
    final found = await _get(
      'https://itunes.apple.com/lookup?id=${ids.join(',')}&entity=song&country=$country',
    );
    final byId = <String, MusicTrack>{};
    final list = found['results'];
    if (list is List) {
      for (final e in list) {
        final t = _track(e);
        if (t != null) byId[t.remoteId] = t;
      }
    }
    final out = [
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
    if (out.isNotEmpty) {
      _chart = out;
      _chartAt = DateTime.now();
    }
    return out;
  }

  /// The address of the 30 second preview of [t].
  Future<String> previewUrl(MusicTrack t) async {
    if (t.previewUrl.isNotEmpty) return t.previewUrl;
    final known = _previews[t.id];
    if (known != null) return known;
    final r = await _get(
      'https://itunes.apple.com/lookup?id=${t.remoteId}&entity=song&country=$country',
    );
    final list = r['results'];
    if (list is List) {
      for (final e in list) {
        final x = _track(e);
        if (x != null && x.id == t.id) return x.previewUrl;
      }
    }
    throw const MediaException('That song is not available any more.');
  }

  /// Tests replace this to avoid a network.
  Future<File> Function(MusicTrack t)? downloadBackend;

  /// Saves the preview as a file on the phone (it is merged into a video from there).
  Future<File> downloadPreview(MusicTrack t) async {
    final b = downloadBackend;
    if (b != null) return b(t);
    final url = await previewUrl(t);
    final ext = url.contains('.mp3') ? 'mp3' : 'm4a';
    final file = File(
      '${Directory.systemTemp.path}/instantgram_song_${t.remoteId}.$ext',
    );
    if (await file.exists() && await file.length() > 10000) return file;
    try {
      await _dio.download(url, file.path);
    } on DioException {
      throw const MediaException(
        'Could not download the song. Check your connection.',
      );
    }
    return file;
  }
}
