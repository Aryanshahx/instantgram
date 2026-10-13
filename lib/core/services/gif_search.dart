import 'api_client.dart';

/// One GIF from GIF search.
class GifResult {
  const GifResult({
    required this.id,
    required this.url,
    required this.preview,
    required this.width,
    required this.height,
  });

  final String id;
  final String url; // sent in the comment
  final String preview; // small, for the picker grid
  final int width;
  final int height;

  static GifResult? fromMap(Object? v) {
    if (v is! Map) return null;
    final url = v['url'];
    if (url is! String || !url.startsWith('https://')) return null;
    final prev = v['preview'];
    return GifResult(
      id: '${v['id'] ?? ''}',
      url: url,
      preview: prev is String && prev.startsWith('https://') ? prev : url,
      width: (v['width'] as num?)?.toInt() ?? 200,
      height: (v['height'] as num?)?.toInt() ?? 200,
    );
  }
}

/// A page of GIFs. [next] = offset of the next page (null = no more).
class GifPage {
  const GifPage(this.gifs, this.next);
  final List<GifResult> gifs;
  final int? next;
}

/// GIF search for comments (GIPHY, through our server: /api/gifs).
class GifSearch {
  GifSearch._();
  static final GifSearch instance = GifSearch._();

  /// Tests replace the server call.
  static Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
  debugPost;

  /// Empty [query] = trending GIFs.
  /// Throws [GifSearchOff] when the server has no GIPHY key yet.
  Future<GifPage> search(String query, {int offset = 0}) async {
    final body = {'q': query.trim(), 'offset': offset};
    final Map<String, dynamic> res;
    try {
      res = await (debugPost?.call(body) ??
          ApiClient.instance.post('/api/gifs', body));
    } on ApiException catch (e) {
      if (e.statusCode == 503 || e.statusCode == 404) {
        throw const GifSearchOff();
      }
      rethrow;
    }
    final list = (res['gifs'] as List?) ?? const [];
    return GifPage(
      [
        for (final g in list) ?GifResult.fromMap(g),
      ],
      (res['next'] as num?)?.toInt(),
    );
  }
}

/// GIF search is not set up on the server (GIPHY_API_KEY missing).
class GifSearchOff implements Exception {
  const GifSearchOff();
  @override
  String toString() => 'GIF search is not set up yet';
}
