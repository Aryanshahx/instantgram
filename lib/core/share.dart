import 'package:share_plus/share_plus.dart';

import '../models/post.dart';

/// The link that is shared for a post: the video, or the photo.
String shareLinkFor(Post post) => post.isVideo ? post.videoUrl : post.imageUrl;

/// Opens the system share sheet with the link only (no caption, no extra text).
Future<void> sharePost(Post post) async {
  final link = shareLinkFor(post);
  if (link.isEmpty) return;
  await Share.share(link);
}
