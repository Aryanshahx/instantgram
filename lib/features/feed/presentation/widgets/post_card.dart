import 'package:flutter/material.dart';

import '../../../insights/owner_sheet.dart';

import '../../../../core/services/content_filter.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/errors.dart';
import '../../../../core/utils/share.dart';
import '../../../../core/utils/time_ago.dart';
import '../../../../shared/models/post.dart';
import '../../../../shared/navigation.dart';
import '../../../../shared/widgets/avatar.dart';
import '../../../../shared/widgets/media_view.dart';
import '../../../post/data/post_repository.dart';
import '../../../post/presentation/comments_sheet.dart';
import '../../../post/presentation/post_menu.dart';

class PostCard extends StatefulWidget {
  const PostCard({
    super.key,
    required this.post,
    this.onDeleted,
    this.source = ViewSource.feed,
  });

  final Post post;
  final VoidCallback? onDeleted;

  /// Where it is shown (for Analytics).
  final String source;

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard>
    with SingleTickerProviderStateMixin {
  final _repo = PostRepository.instance;
  late final AnimationController _heart = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  // optimistic UI: null = follow server state
  bool? _likedOverride;
  int _likeDelta = 0;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant PostCard old) {
    super.didUpdateWidget(old);
    // server count changed -> drop local delta
    if (old.post.likesCount != widget.post.likesCount) _likeDelta = 0;
  }

  @override
  void dispose() {
    _heart.dispose();
    super.dispose();
  }

  Future<void> _setLiked(bool serverLiked, bool like) async {
    if (_busy || serverLiked == like) return;
    setState(() {
      _busy = true;
      _likedOverride = like;
      _likeDelta = like ? 1 : -1;
    });
    try {
      await _repo.setLiked(widget.post, like);
    } catch (e) {
      if (mounted) {
        setState(() => _likeDelta = 0);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _likedOverride = null;
        });
      }
    }
  }

  Future<void> _toggle(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.post;
    final mine = p.authorId == ContentFilter.instance.uid;

    return StreamBuilder<bool>(
      stream: _repo.isLiked(p.id),
      builder: (context, likedSnap) {
        final serverLiked = likedSnap.data ?? false;
        final liked = _likedOverride ?? serverLiked;
        final likes = (p.likesCount + _likeDelta).clamp(0, 1 << 31);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => openProfile(context, p.authorId),
                    child: Avatar(
                      url: p.authorPhotoUrl,
                      name: p.authorUsername,
                      size: 38,
                      uid: p.authorId,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => openProfile(context, p.authorId),
                      child: Text(
                        p.authorUsername,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  if (p.pinned)
                    const Icon(
                      Icons.push_pin,
                      size: 18,
                      color: AppColors.textSecondary,
                    ),
                  IconButton(
                    onPressed: () =>
                        showPostMenu(context, p, onDeleted: widget.onDeleted),
                    icon: const Icon(Icons.more_horiz),
                  ),
                ],
              ),
            ),
            // Media (real shape, autoplay, swipe)
            PostMedia(
              post: p,
              onTap: p.isClip
                  ? () => openPost(context, [p], 0, source: ViewSource.feed)
                  : null,
              onDoubleTap: () {
                _heart.forward(from: 0);
                _setLiked(serverLiked, true);
              },
              onLongPress: p.authorId == ContentFilter.instance.uid
                  ? () => showOwnerQuickSheet(context, p)
                  : null,
              onSeen: () => _repo.addView(p, source: widget.source),
              onWatched: (ms, done) =>
                  _repo.reportWatch(p, watchMs: ms, completed: done),
              overlay: IgnorePointer(
                child: Center(
                  child: AnimatedBuilder(
                    animation: _heart,
                    builder: (context, _) {
                      final t = _heart.value;
                      if (t == 0 || t == 1) return const SizedBox.shrink();
                      final scale = t < 0.3
                          ? t / 0.3 * 1.2
                          : 1.2 - (t - 0.3) * 0.3;
                      return Opacity(
                        opacity: t < 0.7 ? 1 : (1 - t) / 0.3,
                        child: Transform.scale(
                          scale: scale,
                          child: const Icon(
                            Icons.favorite,
                            size: 110,
                            color: Colors.white,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            // Actions
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => _setLiked(serverLiked, !liked),
                    icon: Icon(
                      liked ? Icons.favorite : Icons.favorite_border,
                      color: liked ? AppColors.like : null,
                      size: 28,
                    ),
                  ),
                  IconButton(
                    onPressed: () => showComments(context, p),
                    icon: const Icon(Icons.chat_bubble_outline, size: 26),
                  ),
                  StreamBuilder<bool>(
                    stream: _repo.isReposted(p.id),
                    builder: (context, s) {
                      final reposted = s.data ?? false;
                      return IconButton(
                        onPressed: () =>
                            _toggle(() => _repo.setReposted(p, !reposted)),
                        icon: Icon(
                          Icons.repeat,
                          size: 27,
                          color: reposted ? AppColors.lime : null,
                        ),
                      );
                    },
                  ),
                  IconButton(
                    onPressed: () => sharePost(p),
                    icon: const Icon(Icons.send_outlined, size: 26),
                  ),
                  if (p.sharesCount > 0 && (!p.hideShares || mine))
                    Text(
                      compactCount(p.sharesCount),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  const Spacer(),
                  StreamBuilder<bool>(
                    stream: _repo.isSaved(p.id),
                    builder: (context, s) {
                      final saved = s.data ?? false;
                      return IconButton(
                        onPressed: () =>
                            _toggle(() => _repo.setSaved(p, !saved)),
                        icon: Icon(
                          saved ? Icons.bookmark : Icons.bookmark_border,
                          size: 28,
                          color: saved ? AppColors.lime : null,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!p.hideLikes || mine)
                    Text(
                      '${compactCount(likes)} ${likes == 1 ? 'like' : 'likes'}'
                      '${p.hideLikes ? ' · hidden from others' : ''}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  if (!mine && p.repostsCount > 0 && !p.hideReposts)
                    Text(
                      '${compactCount(p.repostsCount)} '
                      '${p.repostsCount == 1 ? 'repost' : 'reposts'}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  if (p.caption.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${p.authorUsername} ',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          TextSpan(text: p.caption),
                        ],
                      ),
                    ),
                  ],
                  if (p.commentsCount > 0) ...[
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: () => showComments(context, p),
                      child: Text(
                        p.hideComments && !mine
                            ? 'View comments'
                            : p.commentsCount == 1
                            ? 'View 1 comment'
                            : 'View all ${p.commentsCount} comments',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    timeAgo(p.createdAt),
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
