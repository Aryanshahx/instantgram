import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../core/share.dart';
import '../core/ui.dart';
import '../models/chat.dart';
import '../models/post.dart';
import '../screens/post/post_detail_screen.dart';
import '../screens/reels/reels_screen.dart';
import '../services/chat_service.dart';
import '../services/post_service.dart';
import 'recipient_sheet.dart';

/// Picture shown on the shared card: the thumbnail of a video, or the photo itself.
String shareThumbRef(Post p) =>
    p.isVideo ? (p.thumbRef.isNotEmpty ? p.thumbRef : '') : p.imageRef;

/// "Send to people" or "Share link" for a post or clip.
Future<void> showShareSheet(BuildContext context, Post post) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const ValueKey('shareToChat'),
            leading: const Icon(Icons.send_rounded),
            title: const Text('Send to people'),
            subtitle: const Text('In InstantGram chats'),
            onTap: () => Navigator.pop(ctx, 'chat'),
          ),
          ListTile(
            key: const ValueKey('shareLink'),
            leading: const Icon(Icons.ios_share_rounded),
            title: const Text('Share link'),
            subtitle: const Text('WhatsApp, Messages and other apps'),
            onTap: () => Navigator.pop(ctx, 'link'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'link') {
    try {
      await sharePost(post);
    } catch (_) {
      if (context.mounted) showToast(context, 'Could not open the share menu.');
    }
    return;
  }
  final pick = await pickRecipients(
    context,
    title: post.isClip ? 'Send this clip' : 'Send this post',
    withNote: true,
  );
  if (pick == null || !context.mounted) return;
  try {
    for (final u in pick.users) {
      await ChatService.instance.sendPost(
        u.uid,
        postId: post.id,
        thumbRef: shareThumbRef(post),
        title: post.caption,
        author: post.authorUsername,
        isClip: post.isClip,
        note: pick.note,
      );
    }
    if (context.mounted) {
      showToast(
        context,
        pick.users.length == 1
            ? 'Sent to ${pick.users.first.username}'
            : 'Sent to ${pick.users.length} people',
      );
    }
  } catch (e) {
    if (context.mounted) showToast(context, friendlyError(e));
  }
}

/// Opens a post that was sent in a chat.
Future<void> openSharedPost(BuildContext context, ChatMessage m) async {
  try {
    final p = await PostService.instance.getPost(m.postId);
    if (!context.mounted) return;
    if (p == null || p.isLegacyLink) {
      showToast(context, 'This post is no longer available.');
      return;
    }
    if (p.isClip) {
      openClips(context, p);
    } else {
      openScreen(context, PostDetailScreen(post: p));
    }
  } catch (e) {
    if (context.mounted) showToast(context, friendlyError(e));
  }
}
