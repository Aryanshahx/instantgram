import 'package:flutter/material.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../core/errors.dart';
import '../core/theme.dart';
import '../core/share.dart';
import '../core/ui.dart';
import '../models/post.dart';
import '../screens/post/comments_screen.dart';
import '../screens/profile/profile_screen.dart';
import '../screens/reels/reels_screen.dart';
import '../services/post_service.dart';
import '../services/user_service.dart';
import 'avatar.dart';
import 'like_button.dart';
import 'music_widgets.dart';
import 'post_media.dart';
import 'reel_actions.dart';
import 'save_controller.dart';

/// A post in Discover: author on top, the photo or clip in its real proportions (square
/// corners, nothing drawn over it), then like and comment under it.
class PostCard extends StatefulWidget {
  const PostCard({super.key, required this.post, this.onDeleted});

  final Post post;
  final VoidCallback? onDeleted;

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  late final LikeController _like;
  late final SaveController _save;
  late int _comments;
  bool _heart = false;
  bool _expanded = false;

  Post get post => widget.post;
  bool get _mine => post.authorId == UserService.instance.myUid;

  @override
  void initState() {
    super.initState();
    _like = LikeController(post.id, post.likeCount);
    _save = SaveController(post.id);
    _comments = post.commentCount;
  }

  @override
  void dispose() {
    _like.dispose();
    _save.dispose();
    super.dispose();
  }

  void _openProfile() => openScreen(context, ProfileScreen(uid: post.authorId));

  void _openMedia() {
    if (post.isClip) openClips(context, post);
  }

  Future<void> _doubleTapLike() async {
    setState(() => _heart = true);
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _heart = false);
    });
    final err = await _like.setLiked(true);
    if (err != null && mounted) showToast(context, friendlyError(err));
  }

  void _openComments() {
    showCommentsSheet(
      context,
      post: post,
      onCountChanged: (delta) {
        if (mounted) {
          setState(() => _comments = (_comments + delta).clamp(0, 1 << 30));
        }
      },
    );
  }

  Future<void> _toggleSave() async {
    final err = await _save.toggle();
    if (!mounted) return;
    if (err != null) {
      showToast(context, friendlyError(err));
    } else {
      showToast(
        context,
        _save.saved ? 'Saved to your profile' : 'Removed from saved',
      );
    }
  }

  Future<void> _share() async {
    try {
      await sharePost(post);
    } catch (_) {
      if (mounted) showToast(context, 'Could not open the share menu.');
    }
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
    final size = MediaQuery.sizeOf(context);
    final maxMediaHeight = size.height * (size.width > 600 ? 0.72 : 0.92);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: context.hairline.withValues(alpha: 0.7)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(context),
          GestureDetector(
            onTap: _openMedia,
            onDoubleTap: _doubleTapLike,
            child: Stack(
              children: [
                PostMedia(post: post, maxHeight: maxMediaHeight, inline: true),
                if (post.hasMusic)
                  Positioned(
                    left: 10,
                    bottom: 10,
                    child: MusicToggleChip(
                      post: post,
                      interactive: !post.isVideo,
                    ),
                  ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: AnimatedScale(
                        scale: _heart ? 1 : 0.3,
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOutBack,
                        child: AnimatedOpacity(
                          opacity: _heart ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: const Icon(
                            Icons.favorite_rounded,
                            color: kHeartColor,
                            size: 110,
                            shadows: kReelShadow,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _actions(context),
          _info(context),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 8),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openProfile,
              child: Row(
                children: [
                  UserAvatar(
                    url: post.authorPhotoUrl,
                    name: post.authorUsername,
                    radius: 17,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      post.authorUsername,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_mine)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (v) {
                if (v == 'delete') _delete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
        ],
      ),
    );
  }

  /// Heart and comment, directly under the media.
  Widget _actions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
      child: Row(
        children: [
          HeartButton(
            controller: _like,
            onError: (e) {
              if (mounted) showToast(context, friendlyError(e));
            },
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _openComments,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.chat_bubble_outline_rounded, size: 26),
                  const SizedBox(width: 6),
                  Text(
                    '$_comments',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _share,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Icon(Icons.ios_share_rounded, size: 25),
            ),
          ),
          ListenableBuilder(
            listenable: _save,
            builder: (context, _) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleSave,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Icon(
                  _save.saved
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  size: 27,
                  color: _save.saved ? context.accentInk : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _info(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (post.caption.isNotEmpty)
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: post.authorUsername,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    TextSpan(text: '  ${post.caption}'),
                  ],
                ),
                maxLines: _expanded ? null : 3,
                overflow: _expanded
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, height: 1.35),
              ),
            ),
          const SizedBox(height: 6),
          Text(
            timeago.format(post.createdAt),
            style: TextStyle(color: context.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
