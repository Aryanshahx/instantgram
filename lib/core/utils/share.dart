import 'package:share_plus/share_plus.dart';

import '../../shared/models/post.dart';
import '../../shared/models/user_profile.dart';

Future<void> sharePost(Post post) {
  final what = post.isClip ? 'clip' : 'post';
  final caption = post.caption.isEmpty ? '' : '"${post.caption}"\n';
  return SharePlus.instance.share(
    ShareParams(
      text: 'Check out this $what by @${post.authorUsername} on InstantGram\n'
          '$caption${post.mediaUrl}',
    ),
  );
}

Future<void> shareProfile(UserProfile user) {
  return SharePlus.instance.share(
    ShareParams(
      text: 'Follow @${user.username} on InstantGram 📸'
          '${user.website.isNotEmpty ? '\n${user.website}' : ''}',
    ),
  );
}
