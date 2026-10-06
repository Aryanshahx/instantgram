import 'package:flutter/material.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../core/errors.dart';
import '../core/hashtags.dart';
import '../services/view_tracker.dart';
import '../core/theme.dart';
import 'share_sheet.dart';
import '../core/ui.dart';
import '../models/post.dart';
import '../services/user_service.dart';
import '../screens/post/comments_screen.dart';
import '../screens/profile/profile_screen.dart';
import '../screens/reels/reels_screen.dart';
import '../services/safety_service.dart';
import 'avatar.dart';
import 'like_button.dart';
import 'music_widgets.dart';
import 'post_actions_sheet.dart';
import 'post_media.dart';
import 'reel_actions.dart';
import 'repost_controller.dart';
import 'save_controller.dart';

/// A post in Discover: author on top, the photo or clip in its real proportions (square
/// corners, nothing drawn over it), then like and comment under it.
class PostCard extends StatefulWidget {
  const PostCard({
    super.key,
    required this.post,
    this.onDeleted,
    this.inline = false,
  });

  final Post post;

  /// Clips play by themselves while they are on screen (only in the Discover feed).
  final bool inline;
  final VoidCallback? onDeleted;

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  late final LikeController _like;
  late final SaveController _save;
  late final RepostController _repost;
  late int _comments;
  bool _heart = false;
  bool _expanded = false;

  Post get post => widget.post;

  @override
  void initState() {
    super.initState();
    _like = LikeController(post.id, post.likeCount);
    _save = SaveController(post.id);
    _repost = RepostController(post);
    _comments = post.commentCount;
    _unwatch = ViewTracker.instance.watch(post);
  }

  VoidCallback? _unwatch;

  @override
  void dispose() {
    _unwatch?.call();
    _like.dispose();
    _save.dispose();
    _repost.dispose();
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

  Future<void> _toggleRepost() async {
    final err = await _repost.toggle();
    if (!mounted) return;
    showToast(
      context,
      err != null
          ? friendlyError(err)
          : (_repost.reposted ? 'Reposted to your profile' : 'Repost removed'),
    );
  }

  Future<void> _share() async {
    try {
      await showShareSheet(context, post);
    } catch (_) {
      if (mounted) showToast(context, 'Could not open the share menu.');
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
                PostMedia(
                  post: post,
                  maxHeight: maxMediaHeight,
                  inline: widget.inline || post.isCarousel,
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
                    uid: post.authorId,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          post.authorUsername,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                        // the audio name goes right under the username
                        if (post.hasMusic)
                          MusicLabel(musicId: post.musicId, onDark: false),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('postMore'),
            icon: const Icon(Icons.more_horiz_rounded),
            onPressed: () => showPostActions(
              context,
              post,
              onDeleted: widget.onDeleted,
            ),
          ),
        ],
      ),
    );
  }

  /// Heart, comment and repost on the left; share and save on the right.
  Widget _actions(BuildContext context) {
    final mine = post.authorId == UserService.instance.myUid;
    Widget icon(Key? key, IconData data, VoidCallback onTap, {Color? color}) =>
        GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 8),
            child: Icon(data, size: 23, color: color),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 0),
      child: Row(
        children: [
          HeartButton(
            controller: _like,
            showCount: SafetyService.instance.showsNumber(post, post.hideLikes),
            onError: (e) {
              if (mounted) showToast(context, friendlyError(e));
            },
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _openComments,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.mode_comment_outlined, size: 22),
                  if (SafetyService.instance.showsNumber(
                    post,
                    post.hideComments,
                  )) ...[
                    const SizedBox(width: 5),
                    Text(
                      '$_comments',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (!mine)
            ListenableBuilder(
              listenable: _repost,
              builder: (context, _) => icon(
                const ValueKey('cardRepost'),
                Icons.repeat_rounded,
                _toggleRepost,
                color: _repost.reposted ? context.accentInk : null,
              ),
            ),
          const Spacer(),
          icon(null, Icons.ios_share_rounded, _share),
          ListenableBuilder(
            listenable: _save,
            builder: (context, _) => icon(
              null,
              _save.saved
                  ? Icons.bookmark_rounded
                  : Icons.bookmark_border_rounded,
              _toggleSave,
              color: _save.saved ? context.accentInk : null,
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
              child: HashtagText(
                '  ${post.caption}',
                leading: [
                  TextSpan(
                    text: post.authorUsername,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ],
                tagColor: context.accentInk,
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
