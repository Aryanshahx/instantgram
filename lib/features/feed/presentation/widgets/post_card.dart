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
import '../../../../shared/widgets/bounce.dart';

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
                  // icon + count (a count is hidden when the author
                  // switched it off; the author still sees it)
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ActionCount(
                            key: const ValueKey('count-like'),
                            onTap: () => _setLiked(serverLiked, !liked),
                            trigger: liked,
                            icon: Icon(
                              liked ? Icons.favorite : Icons.favorite_border,
                              color: liked ? AppColors.like : null,
                              size: 27,
                            ),
                            count: likes,
                            hidden: p.hideLikes && !mine,
                          ),
                          ActionCount(
                            key: const ValueKey('count-comment'),
                            onTap: () => showComments(context, p),
                            icon: const Icon(
                              Icons.chat_bubble_outline,
                              size: 25,
                            ),
                            count: p.commentsCount,
                            hidden: p.hideComments && !mine,
                          ),
                          StreamBuilder<bool>(
                            stream: _repo.isReposted(p.id),
                            builder: (context, s) {
                              final reposted = s.data ?? false;
                              return ActionCount(
                                key: const ValueKey('count-repost'),
                                onTap: () => _toggle(
                                  () => _repo.setReposted(p, !reposted),
                                ),
                                trigger: reposted,
                                icon: Icon(
                                  Icons.repeat,
                                  size: 26,
                                  color: reposted ? AppColors.lime : null,
                                ),
                                count: p.repostsCount,
                                hidden: p.hideReposts && !mine,
                              );
                            },
                          ),
                          ActionCount(
                            key: const ValueKey('count-share'),
                            onTap: () => sharePost(context, p),
                            icon: const Icon(Icons.send_outlined, size: 25),
                            count: p.sharesCount,
                            hidden: p.hideShares && !mine,
                          ),
                        ],
                      ),
                    ),
                  ),
                  StreamBuilder<bool>(
                    stream: _repo.isSaved(p.id),
                    builder: (context, s) {
                      final saved = s.data ?? false;
                      return IconButton(
                        onPressed: () =>
                            _toggle(() => _repo.setSaved(p, !saved)),
                        icon: Bounce(
                          trigger: saved,
                          child: Icon(
                            saved ? Icons.bookmark : Icons.bookmark_border,
                            size: 28,
                            color: saved ? AppColors.lime : null,
                          ),
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
                  if (p.caption.isNotEmpty) ...[
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

/// Action icon with its count next to it (no number when 0 or hidden).
class ActionCount extends StatefulWidget {
  const ActionCount({
    super.key,
    required this.icon,
    required this.count,
    required this.hidden,
    required this.onTap,
    this.trigger,
  });

  final Widget icon;
  final int count;
  final bool hidden;
  final VoidCallback onTap;

  /// The icon pops when this changes (liked, reposted…).
  final Object? trigger;

  @override
  State<ActionCount> createState() => _ActionCountState();
}

class _ActionCountState extends State<ActionCount> {
  final _bounce = GlobalKey<BounceState>();

  @override
  Widget build(BuildContext context) {
    final show = !widget.hidden && widget.count > 0;
    return InkWell(
      onTap: () {
        _bounce.currentState?.play();
        widget.onTap();
      },
      customBorder: const StadiumBorder(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Bounce(key: _bounce, trigger: widget.trigger, child: widget.icon),
            if (show) ...[
              const SizedBox(width: 5),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, 0.4),
                      end: Offset.zero,
                    ).animate(a),
                    child: child,
                  ),
                ),
                child: Text(
                  compactCount(widget.count),
                  key: ValueKey(widget.count),
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
