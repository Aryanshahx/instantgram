import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../features/chats/presentation/share_sheet.dart';
import '../../features/post/data/post_repository.dart';
import '../../shared/models/post.dart';
import '../../shared/models/user_profile.dart';

/// Share button: opens the in-app share sheet (send to people you follow
/// or chat with, copy link, or other apps).
Future<void> sharePost(BuildContext context, Post post) =>
    showShareSheet(context, post);

/// Public link of the post's media.
String postLink(Post post) =>
    post.coverUrl.isNotEmpty ? post.coverUrl : post.mediaUrl;

/// System share (WhatsApp, Telegram, ...). +1 share when sent.
Future<void> shareToOtherApps(Post post) async {
  final what = post.isClip ? 'clip' : 'post';
  final caption = post.caption.isEmpty ? '' : '"${post.caption}"\n';
  final res = await SharePlus.instance.share(
    ShareParams(
      text:
          'Check out this $what by @${post.authorUsername} on InstantGram\n'
          '$caption${postLink(post)}',
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
