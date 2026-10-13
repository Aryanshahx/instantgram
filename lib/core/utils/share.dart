import 'package:share_plus/share_plus.dart';

import '../../shared/models/post.dart';
import '../../shared/models/user_profile.dart';
import '../../features/post/data/post_repository.dart';

/// Opens the share sheet and adds +1 to the post's share count.
Future<void> sharePost(Post post) async {
  final what = post.isClip ? 'clip' : 'post';
  final caption = post.caption.isEmpty ? '' : '"${post.caption}"\n';
  final res = await SharePlus.instance.share(
    ShareParams(
      text:
          'Check out this $what by @${post.authorUsername} on InstantGram\n'
          '$caption${post.coverUrl.isNotEmpty ? post.coverUrl : post.mediaUrl}',
    ),
  );
  if (res.status != ShareResultStatus.dismissed) {
    await PostRepository.instance.addShare(post);
  }
}

Future<void> shareProfile(UserProfile user) {
  return SharePlus.instance.share(
    ShareParams(
      text:
          'Follow @${user.username} on InstantGram 📸'
          '${user.website.isNotEmpty ? '\n${user.website}' : ''}',
    ),
  );
}
