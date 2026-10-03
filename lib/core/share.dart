import 'package:share_plus/share_plus.dart';

import '../models/post.dart';

/// Opens the system share sheet with the caption and a link to the post media.
Future<void> sharePost(Post post) async {
  final link = post.isVideo ? post.videoUrl : post.imageUrl;
  final parts = <String>[
    if (post.caption.trim().isNotEmpty) post.caption.trim(),
    if (link.isNotEmpty) link,
    'Shared from Instantgram by @${post.authorUsername}',
  ];
  await Share.share(parts.join('\n\n'));
}
