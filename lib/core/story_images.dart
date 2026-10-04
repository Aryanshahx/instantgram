import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

/// One place that decides how a moment's picture is loaded, so the copy fetched in advance
/// (while the feed is open) is exactly the one the viewer shows.
ImageProvider storyImageProvider(BuildContext context, String url) {
  final mq = MediaQuery.of(context);
  final w = (mq.size.width * mq.devicePixelRatio).clamp(720, 1440).round();
  return CachedNetworkImageProvider(url, maxWidth: w);
}

/// Loads a moment's picture into memory without showing it (errors are ignored).
Future<void> warmStoryImage(BuildContext context, String url) async {
  if (url.isEmpty) return;
  try {
    await precacheImage(storyImageProvider(context, url), context);
  } catch (_) {}
}
