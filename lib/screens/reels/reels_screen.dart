import 'package:flutter/material.dart';

import '../../core/app_events.dart';
import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/post.dart';
import '../../models/video_link.dart';
import '../../services/post_pager.dart';
import '../../services/post_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/glass.dart';
import '../../widgets/like_button.dart';
import '../../widgets/state_views.dart';
import '../../widgets/video_embed.dart';
import '../../widgets/video_thumb.dart';
import '../post/comments_screen.dart';
import '../profile/profile_screen.dart';

/// Vertical feed of video-link posts. Only the visible page creates a player.
class ReelsScreen extends StatefulWidget {
  const ReelsScreen({super.key, required this.active});

  /// false while another tab is selected (stops playback).
  final bool active;

  @override
  State<ReelsScreen> createState() => _ReelsScreenState();
}

class _ReelsScreenState extends State<ReelsScreen> {
  late final PostPager _pager =
      PostPager(PostService.instance.videoQuery, pageSize: 8);
  final PageController _pages = PageController();
  int _page = 0;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    AppEvents.feedRefresh.addListener(_refresh);
  }

  void _refresh() {
    if (_started) _pager.refresh();
  }

  @override
  void dispose() {
    AppEvents.feedRefresh.removeListener(_refresh);
    _pager.dispose();
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Lazy: do not hit Firestore until the Reels tab is first opened.
    if (widget.active && !_started) {
      _started = true;
      _pager.loadMore();
    }
    if (!_started) return const ColoredBox(color: Colors.black);

    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: ColoredBox(
        color: Colors.black,
        child: ListenableBuilder(
          listenable: _pager,
          builder: (context, _) {
            if (_pager.initialLoading) return const CenteredLoader();
            if (_pager.error != null && _pager.posts.isEmpty) {
              return ErrorState(error: _pager.error!, onRetry: _pager.retry);
            }
            if (_pager.posts.isEmpty) {
              return const EmptyState(
                icon: Icons.smart_display_outlined,
                title: 'No clips yet',
                subtitle:
                    'Share a YouTube Short, TikTok or Instagram Reel link with the + button.',
              );
            }
            return PageView.builder(
              scrollDirection: Axis.vertical,
              controller: _pages,
              itemCount: _pager.posts.length,
              onPageChanged: (i) {
                setState(() => _page = i);
                if (i >= _pager.posts.length - 3) _pager.loadMore();
              },
              itemBuilder: (context, i) {
                final post = _pager.posts[i];
                return _ReelPage(
                  key: ValueKey(post.id),
                  post: post,
                  playing: widget.active && i == _page,
                  onNext: () => _pages.nextPage(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOut,
                  ),
                  onPrevious: () => _pages.previousPage(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOut,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ReelPage extends StatefulWidget {
  const _ReelPage({
    super.key,
    required this.post,
    required this.playing,
    required this.onNext,
    required this.onPrevious,
  });

  final Post post;
  final bool playing;
  final VoidCallback onNext;
  final VoidCallback onPrevious;

  @override
  State<_ReelPage> createState() => _ReelPageState();
}

class _ReelPageState extends State<_ReelPage> {
  late final LikeController _like =
      LikeController(widget.post.id, widget.post.likeCount);
  late int _comments = widget.post.commentCount;

  @override
  void dispose() {
    _like.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final platform = post.videoPlatform ?? VideoPlatform.youtube;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.playing)
          VideoEmbed(
            platform: platform,
            videoId: post.videoId,
            url: post.videoUrl,
          )
        else
          VideoThumb(post: post),

        // "Clips" title
        Positioned(
          top: 0,
          left: 0,
          right: 70,
          child: SafeArea(
            bottom: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(18, 12, 12, 20),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black54, Colors.transparent],
                ),
              ),
              child: const Text('Clips',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1)),
            ),
          ),
        ),

        // Bottom info. These overlays are opaque so vertical swipes on them
        // change the page even though the video WebView swallows gestures.
        Positioned(
          left: 0,
          right: 70,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 40, 8, kNavSpace - 6),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () =>
                      openScreen(context, ProfileScreen(uid: post.authorId)),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(4, 4, 14, 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        UserAvatar(
                            url: post.authorPhotoUrl,
                            name: post.authorUsername,
                            radius: 15),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text('@${post.authorUsername}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white)),
                        ),
                      ],
                    ),
                  ),
                ),
                if (post.caption.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(post.caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, height: 1.3)),
                ],
              ],
            ),
          ),
        ),

        // Right action rail (also an opaque swipe zone).
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 70,
          child: Container(
            color: Colors.black.withValues(alpha: 0.02),
            padding: const EdgeInsets.only(bottom: kNavSpace - 10),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                GlassIconButton(
                  icon: Icons.keyboard_arrow_up_rounded,
                  size: 40,
                  onTap: widget.onPrevious,
                ),
                const SizedBox(height: 8),
                GlassIconButton(
                  icon: Icons.keyboard_arrow_down_rounded,
                  size: 40,
                  onTap: widget.onNext,
                ),
                const SizedBox(height: 22),
                LikeIconButton(
                  controller: _like,
                  onError: (e) {
                    if (mounted) showToast(context, friendlyError(e));
                  },
                ),
                const SizedBox(height: 4),
                ListenableBuilder(
                  listenable: _like,
                  builder: (_, _) => Text('${_like.count}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w800)),
                ),
                const SizedBox(height: 14),
                GlassIconButton(
                  icon: Icons.chat_bubble_outline_rounded,
                  size: 50,
                  onTap: () => openScreen(
                    context,
                    CommentsScreen(
                      post: post,
                      onCountChanged: (d) {
                        if (mounted) setState(() => _comments += d);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text('$_comments',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 14),
                GlassIconButton(
                  icon: Icons.open_in_new_rounded,
                  size: 44,
                  tooltip: 'Open in ${platform.label}',
                  onTap: () => openExternally(post.videoUrl),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
