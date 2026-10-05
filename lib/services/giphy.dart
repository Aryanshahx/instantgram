import 'package:dio/dio.dart';

import '../core/errors.dart';
import '../core/giphy_key.dart';

/// One GIF result.
class GifItem {
  const GifItem({
    required this.id,
    required this.url,
    required this.previewUrl,
    required this.width,
    required this.height,
  });

  final String id;

  /// What gets sent (a size that is fast to load).
  final String url;

  /// What the picker grid shows.
  final String previewUrl;
  final int width;
  final int height;

  double get aspect => (width > 0 && height > 0) ? width / height : 1;

  /// Reads one entry of the Giphy `data` list; null when it has no usable picture.
  static GifItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final images = raw['images'];
    if (images is! Map) return null;
    Map<dynamic, dynamic>? pick(List<String> names) {
      for (final n in names) {
        final v = images[n];
        if (v is Map && v['url'] is String && (v['url'] as String).isNotEmpty) {
          return v;
        }
      }
      return null;
    }

    final main = pick(['fixed_width', 'downsized', 'original']);
    if (main == null) return null;
    final small = pick(['fixed_width_small', 'fixed_width']) ?? main;
    int n(Object? v) => int.tryParse('${v ?? ''}') ?? 0;
    return GifItem(
      id: raw['id'] is String ? raw['id'] as String : (main['url'] as String),
      url: main['url'] as String,
      previewUrl: small['url'] as String,
      width: n(main['width']),
      height: n(main['height']),
    );
  }
}

/// Giphy search (https://developers.giphy.com/docs/api/endpoint).
class GiphyClient {
  GiphyClient({Dio? dio, String? key})
    : _dio =
          dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 12))),
      _key = key ?? kGiphyKey;

  final Dio _dio;
  final String _key;

  static const _base = 'https://api.giphy.com/v1/gifs';

  bool get configured => _key.trim().isNotEmpty;

  Future<List<GifItem>> trending({int limit = 30}) =>
      _get('trending', {'limit': limit});

  Future<List<GifItem>> search(String query, {int limit = 30}) {
    final q = query.trim();
    if (q.isEmpty) return trending(limit: limit);
    return _get('search', {'q': q, 'limit': limit});
  }

  Future<List<GifItem>> _get(String path, Map<String, Object> params) async {
    if (!configured) {
      throw const MediaException('GIFs are not set up (missing Giphy key).');
    }
    try {
      final r = await _dio.get<Object>(
        '$_base/$path',
        queryParameters: {
          ...params,
          'api_key': _key.trim(),
          'rating': 'g',
          'bundle': 'messaging_non_clips',
        },
      );
      final data = r.data;
      final list = data is Map ? data['data'] : null;
      if (list is! List) return const [];
      return [
        for (final e in list)
          if (GifItem.fromJson(e) case final g?) g,
      ];
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        throw const MediaException(
          'The Giphy key was rejected. Check the key.',
        );
      }
      if (code == 429) {
        throw const MediaException('Giphy limit reached. Try again later.');
      }
      throw const MediaException('Could not load GIFs. Check your connection.');
    }
  }
}
