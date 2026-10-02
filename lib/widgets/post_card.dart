import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../core/errors.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../models/post.dart';
import '../screens/post/comments_screen.dart';
import '../screens/profile/profile_screen.dart';
import '../screens/video/video_player_screen.dart';
import '../services/post_service.dart';
import '../services/user_service.dart';
import 'avatar.dart';
import 'like_button.dart';
import 'video_embed.dart';
import 'video_thumb.dart';

class PostCard extends StatefulWidget {
  const PostCard({super.key, required this.post, this.onDeleted});

  final Post post;
  final VoidCallback? onDeleted;

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  late final LikeController _like;
  late int _comments;
  bool _showHeart = false;
  bool _expanded = false;

  Post get post => widget.post;
  bool get _mine => post.authorId == UserService.instance.myUid;

  @override
  void initState() {
    super.initState();
    _like = LikeController(post.id, post.likeCount);
    _comments = post.commentCount;
  }

  @override
  void dispose() {
    _like.dispose();
    super.dispose();
  }

  void _openProfile() => openScreen(context, ProfileScreen(uid: post.authorId));

  void _openMedia() {
    if (post.isVideo) openScreen(context, VideoPlayerScreen(post: post));
  }

  Future<void> _doubleTapLike() async {
    setState(() => _showHeart = true);
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _showHeart = false);
    });
    final err = await _like.setLiked(true);
    if (err != null && mounted) showToast(context, friendlyError(err));
  }

  void _openComments() {
    openScreen(
      context,
      CommentsScreen(
        post: post,
        onCountChanged: (delta) {
          if (mounted) setState(() => _comments = (_comments + delta).clamp(0, 1 << 30));
        },
      ),
    );
  }

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      title: 'Delete post?',
      message: 'This cannot be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    try {
      await PostService.instance.deletePost(post);
      widget.onDeleted?.call();
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context),
        _media(context),
        _actions(context),
        _likesAndCaption(context),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: _openProfile,
            child: UserAvatar(url: post.authorPhotoUrl, radius: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              onTap: _openProfile,
              child: Text(post.authorUsername,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
          if (_mine)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz),
              onSelected: (v) {
                if (v == 'delete') _delete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            )
          else
            const SizedBox(height: 48),
        ],
      ),
    );
  }

  Widget _media(BuildContext context) {
    final child = post.isVideo
        ? VideoThumb(post: post)
        : CachedNetworkImage(
            imageUrl: post.imageUrl,
            fit: BoxFit.cover,
            placeholder: (_, _) => ColoredBox(color: context.softFill),
            errorWidget: (_, _, _) => ColoredBox(
              color: context.softFill,
              child: Icon(Icons.broken_image_outlined, color: context.muted),
            ),
          );

    return GestureDetector(
      onTap: _openMedia,
      onDoubleTap: _doubleTapLike,
      child: AspectRatio(
        aspectRatio: 4 / 5,
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            Center(
              child: AnimatedScale(
                scale: _showHeart ? 1 : 0.3,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutBack,
                child: AnimatedOpacity(
                  opacity: _showHeart ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.favorite, color: Colors.white, size: 96),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          LikeIconButton(
            controller: _like,
            onError: (e) {
              if (mounted) showToast(context, friendlyError(e));
            },
          ),
          IconButton(
            onPressed: _openComments,
            icon: const Icon(Icons.mode_comment_outlined),
          ),
          if (post.isVideo) ...[
            IconButton(
              tooltip: 'Open original',
              onPressed: () => openExternally(post.videoUrl),
              icon: const Icon(Icons.open_in_new),
            ),
            IconButton(
              tooltip: 'Copy link',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: post.videoUrl));
                if (context.mounted) showToast(context, 'Link copied');
              },
              icon: const Icon(Icons.send_outlined),
            ),
          ],
        ],
      ),
    );
  }

  Widget _likesAndCaption(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListenableBuilder(
            listenable: _like,
            builder: (_, _) => Text(
              _like.count == 1 ? '1 like' : '${_like.count} likes',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          if (post.caption.isNotEmpty) ...[
            const SizedBox(height: 4),
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: '${post.authorUsername} ',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(text: post.caption),
                ]),
                maxLines: _expanded ? null : 2,
                overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
              ),
            ),
          ],
          const SizedBox(height: 6),
          GestureDetector(
            onTap: _openComments,
            child: Text(
              _comments > 0
                  ? 'View all $_comments comments'
                  : 'Add a comment...',
              style: TextStyle(color: context.muted),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            timeago.format(post.createdAt).toUpperCase(),
            style: TextStyle(color: context.muted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
