import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../core/errors.dart';
import '../core/media_url.dart';
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
import 'video_thumb.dart';

/// Card-style post: the media sits inside a rounded frame, the author and the
/// actions float on top of it as pills, caption below.
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
  bool _showBolt = false;
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
    setState(() => _showBolt = true);
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _showBolt = false);
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
          if (mounted) {
            setState(() => _comments = (_comments + delta).clamp(0, 1 << 30));
          }
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
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: context.card,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: context.hairline.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [_media(context), _info(context)],
      ),
    );
  }

  Widget _media(BuildContext context) {
    final media = post.isVideo
        ? VideoThumb(post: post, showBadge: false)
        : CachedNetworkImage(
            imageUrl: post.imageUrl,
            fit: BoxFit.cover,
            placeholder: (_, _) => ColoredBox(color: context.cardHigh),
            errorWidget: (_, _, _) => ColoredBox(
              color: context.cardHigh,
              child: Icon(Icons.broken_image_outlined, color: context.muted),
            ),
          );

    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: AspectRatio(
        aspectRatio: MediaQuery.sizeOf(context).width > 600 ? 1.0 : 4 / 5,
        child: GestureDetector(
          onTap: _openMedia,
          onDoubleTap: _doubleTapLike,
          child: Stack(
            fit: StackFit.expand,
            children: [
              media,
              // soft scrims so the pills stay readable on any photo
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black38,
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black45,
                    ],
                    stops: [0, 0.22, 0.7, 1],
                  ),
                ),
              ),
              Center(
                child: AnimatedScale(
                  scale: _showBolt ? 1 : 0.3,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutBack,
                  child: AnimatedOpacity(
                    opacity: _showBolt ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(
                      Icons.bolt_rounded,
                      color: AppTheme.volt,
                      size: 120,
                    ),
                  ),
                ),
              ),
              Positioned(top: 10, left: 10, child: _authorChip()),
              if (_mine)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: BoxShape.circle,
                    ),
                    child: PopupMenuButton<String>(
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.more_horiz, color: Colors.white),
                      onSelected: (v) {
                        if (v == 'delete') _delete();
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ),
                ),
              Positioned(
                left: 10,
                bottom: 10,
                child: Row(
                  children: [
                    LikePill(
                      controller: _like,
                      onError: (e) {
                        if (mounted) showToast(context, friendlyError(e));
                      },
                    ),
                    const SizedBox(width: 8),
                    _pill(
                      Icons.chat_bubble_outline_rounded,
                      '$_comments',
                      _openComments,
                    ),
                  ],
                ),
              ),
              if (post.isVideo && post.videoDuration > 0)
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: _pill(
                    Icons.play_arrow_rounded,
                    formatDuration(post.videoDuration),
                    _openMedia,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _authorChip() {
    return GestureDetector(
      onTap: _openProfile,
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            UserAvatar(
              url: post.authorPhotoUrl,
              name: post.authorUsername,
              radius: 14,
            ),
            const SizedBox(width: 8),
            Text(
              '@${post.authorUsername}',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pill(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: Colors.white),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _info(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (post.caption.isNotEmpty)
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Text(
                post.caption,
                maxLines: _expanded ? null : 3,
                overflow: _expanded
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, height: 1.35),
              ),
            ),
          if (post.caption.isNotEmpty) const SizedBox(height: 8),
          Row(
            children: [
              Text(
                timeago.format(post.createdAt),
                style: TextStyle(color: context.muted, fontSize: 12.5),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _openComments,
                child: Text(
                  _comments > 0 ? 'See $_comments comments' : 'Add a comment',
                  style: TextStyle(
                    color: context.accentInk,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
