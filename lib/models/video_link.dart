import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/errors.dart';

enum VideoPlatform { youtube, tiktok, instagram }

extension VideoPlatformX on VideoPlatform {
  String get label {
    switch (this) {
      case VideoPlatform.youtube:
        return 'YouTube';
      case VideoPlatform.tiktok:
        return 'TikTok';
      case VideoPlatform.instagram:
        return 'Instagram';
    }
  }

  static VideoPlatform? fromName(String? n) {
    for (final p in VideoPlatform.values) {
      if (p.name == n) return p;
    }
    return null;
  }
}

/// A parsed video link. Only this text is stored in Firestore (0 bytes of video).
class VideoLink {
  const VideoLink({required this.platform, required this.url, this.id});

  final VideoPlatform platform;
  final String url;

  /// YouTube: 11-char id. TikTok: numeric id (may be null for short links until
  /// resolved). Instagram: "reel/CODE" (kind/code).
  final String? id;

  static final RegExp _ytId = RegExp(r'^[A-Za-z0-9_-]{11}$');

  static VideoLink? parse(String raw) {
    var text = raw.trim();
    if (text.isEmpty || text.contains(' ')) return null;
    if (!text.startsWith('http')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty || !uri.host.contains('.')) return null;

    final host = uri.host.toLowerCase();
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();

    // ---- YouTube / Shorts
    if (host == 'youtu.be' ||
        host.endsWith('youtube.com') ||
        host.endsWith('youtube-nocookie.com')) {
      String? id;
      if (host == 'youtu.be') {
        if (segs.isNotEmpty) id = segs.first;
      } else if (segs.length >= 2 &&
          const {'shorts', 'embed', 'live', 'v'}.contains(segs.first)) {
        id = segs[1];
      } else {
        id = uri.queryParameters['v'];
      }
      if (id != null && _ytId.hasMatch(id)) {
        return VideoLink(platform: VideoPlatform.youtube, url: text, id: id);
      }
      return null;
    }

    // ---- TikTok
    if (host.endsWith('tiktok.com')) {
      String? id;
      final i = segs.indexOf('video');
      if (i >= 0 && i + 1 < segs.length && RegExp(r'^\d+$').hasMatch(segs[i + 1])) {
        id = segs[i + 1];
      }
      if (segs.length >= 3 && segs[0] == 'embed' && RegExp(r'^\d+$').hasMatch(segs[2])) {
        id = segs[2];
      }
      if (id == null && segs.isEmpty) return null;
      return VideoLink(platform: VideoPlatform.tiktok, url: text, id: id);
    }

    // ---- Instagram Reels / posts
    if (host.endsWith('instagram.com') || host == 'instagr.am') {
      const kinds = {'p', 'reel', 'reels', 'tv'};
      String? kind;
      String? code;
      if (segs.length >= 2 && kinds.contains(segs[0])) {
        kind = segs[0];
        code = segs[1];
      } else if (segs.length >= 3 && kinds.contains(segs[1])) {
        kind = segs[1];
        code = segs[2];
      }
      if (kind != null && code != null) {
        if (kind == 'reels') kind = 'reel';
        return VideoLink(
          platform: VideoPlatform.instagram,
          url: text,
          id: '$kind/$code',
        );
      }
      return null;
    }
    return null;
  }

  /// URL loaded inside a WebView for TikTok / Instagram. (YouTube uses the
  /// dedicated iframe player.)
  String? get embedUrl {
    if (id == null) return null;
    switch (platform) {
      case VideoPlatform.tiktok:
        return 'https://www.tiktok.com/embed/v2/$id';
      case VideoPlatform.instagram:
        return 'https://www.instagram.com/$id/embed/';
      case VideoPlatform.youtube:
        return null;
    }
  }
}

class ResolvedVideo {
  const ResolvedVideo({required this.link, this.thumbnailUrl = '', this.title});
  final VideoLink link;
  final String thumbnailUrl;
  final String? title;
}

class VideoLinkResolver {
  static const _timeout = Duration(seconds: 10);

  static String youtubeThumbnail(String id) =>
      'https://img.youtube.com/vi/$id/hqdefault.jpg';

  /// Validates a link and fetches a thumbnail URL when the platform allows it.
  static Future<ResolvedVideo> resolve(String raw) async {
    final link = VideoLink.parse(raw);
    if (link == null) {
      throw const VideoLinkException(
        'Paste a YouTube / YouTube Shorts, TikTok or Instagram Reel link.',
      );
    }

    switch (link.platform) {
      case VideoPlatform.youtube:
        return ResolvedVideo(
          link: link,
          thumbnailUrl: youtubeThumbnail(link.id!),
        );

      case VideoPlatform.instagram:
        // Instagram does not expose thumbnails without an API token.
        return ResolvedVideo(link: link);

      case VideoPlatform.tiktok:
        try {
          final res = await http
              .get(Uri.https('www.tiktok.com', '/oembed', {'url': link.url}))
              .timeout(_timeout);
          if (res.statusCode == 200) {
            final json = jsonDecode(res.body) as Map<String, dynamic>;
            var id = link.id;
            if (id == null) {
              final html = (json['html'] ?? '') as String;
              final m = RegExp(r'data-video-id="(\d+)"').firstMatch(html);
              id = m?.group(1);
            }
            if (id == null) {
              throw const VideoLinkException(
                  'Could not read that TikTok link. Use the full video URL.');
            }
            return ResolvedVideo(
              link: VideoLink(platform: VideoPlatform.tiktok, url: link.url, id: id),
              thumbnailUrl: (json['thumbnail_url'] ?? '') as String,
              title: json['title'] as String?,
            );
          }
        } on VideoLinkException {
          rethrow;
        } catch (_) {
          // fall through
        }
        if (link.id != null) return ResolvedVideo(link: link);
        throw const VideoLinkException(
            'Could not read that TikTok link. Use the full video URL.');
    }
  }
}
