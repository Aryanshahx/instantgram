import 'package:flutter/material.dart';

import '../../core/app_events.dart';
import '../../core/errors.dart';
import '../../core/share.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/post.dart';
import '../../services/post_pager.dart';
import '../../services/post_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/glass.dart';
import '../../widgets/like_button.dart';
import '../../widgets/reel_video.dart';
import '../../widgets/save_controller.dart';
import '../../widgets/state_views.dart';
import '../post/comments_screen.dart';
import '../profile/profile_screen.dart';

/// Vertical feed of uploaded clips. Only the visible clip (and the next one,
/// preloaded) owns a native player.
class ReelsScreen extends StatefulWidget {
  const ReelsScreen({super.key, required this.active});

  /// false while another tab is selected (stops playback).
  final bool active;

  @override
  State<ReelsScreen> createState() => _ReelsScreenState();
}

class _ReelsScreenState extends State<ReelsScreen> {
  late final PostPager _pager = PostPager(
    PostService.instance.videoQuery,
    pageSize: 8,
  );
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
    // Lazy: do not hit Firestore until the Clips tab is first opened.
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
                subtitle: 'Tap + and choose Clips to upload the first video.',
              );
            }
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: PageView.builder(
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
                      preload: widget.active && i == _page + 1,
                      onDeleted: () => _pager.removeById(post.id),
                    );
                  },
                ),
              ),
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
    required this.preload,
    required this.onDeleted,
  });

  final Post post;
  final bool playing;
  final bool preload;
  final VoidCallback onDeleted;

  @override
  State<_ReelPage> createState() => _ReelPageState();
}

class _ReelPageState extends State<_ReelPage> {
  late final LikeController _like = LikeController(
    widget.post.id,
    widget.post.likeCount,
  );
  late final SaveController _save = SaveController(widget.post.id);
  late int _comments = widget.post.commentCount;
  bool _caption = false;

  @override
  void dispose() {
    _like.dispose();
    _save.dispose();
    super.dispose();
  }

  Future<void> _toggleLike() async {
    final err = await _like.toggle();
    if (err != null && mounted) showToast(context, friendlyError(err));
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
      await sharePost(widget.post);
    } catch (_) {
      if (mounted) showToast(context, 'Could not open the share menu.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final live = widget.playing || widget.preload;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (live)
          ReelVideo(
            post: post,
            play: widget.playing,
            progressBottom: kNavSpace - 18,
          )
        else
          const ColoredBox(color: Colors.black),

        // soft scrims (ignore touches so taps still reach the video)
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 140,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black54, Colors.transparent],
                ),
              ),
            ),
          ),
        ),
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 330,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
            ),
          ),
        ),

        // top: title + sound switch
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 14, 0),
              child: Row(
                children: [
                  const Text(
                    'Clips',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                    ),
                  ),
                  const Spacer(),
                  ValueListenableBuilder<bool>(
                    valueListenable: ReelAudio.muted,
                    builder: (_, muted, _) => GlassIconButton(
                      icon: muted
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                      size: 42,
                      onTap: () => ReelAudio.muted.value = !muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // bottom-left: author + caption
        Positioned(
          left: 16,
          right: 84,
          bottom: kNavSpace + 6,
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
                        radius: 15,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          '@${post.authorUsername}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (post.caption.isNotEmpty) ...[
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: () => setState(() => _caption = !_caption),
                  child: Text(
                    post.caption,
                    maxLines: _caption ? 8 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, height: 1.3),
                  ),
                ),
              ],
            ],
          ),
        ),

        // right: action rail
        Positioned(
          right: 10,
          bottom: kNavSpace + 4,
          child: _Rail(
            like: _like,
            save: _save,
            comments: _comments,
            onLike: _toggleLike,
            onSave: _toggleSave,
            onShare: _share,
            onComments: () => openScreen(
              context,
              CommentsScreen(
                post: post,
                onCountChanged: (d) {
                  if (mounted) setState(() => _comments += d);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.like,
    required this.save,
    required this.comments,
    required this.onLike,
    required this.onSave,
    required this.onShare,
    required this.onComments,
  });

  final LikeController like;
  final SaveController save;
  final int comments;
  final VoidCallback onLike;
  final VoidCallback onSave;
  final VoidCallback onShare;
  final VoidCallback onComments;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListenableBuilder(
          listenable: like,
          builder: (_, _) => _RailButton(
            icon: Icons.bolt_rounded,
            label: '${like.count}',
            active: like.liked,
            onTap: onLike,
          ),
        ),
        const SizedBox(height: 14),
        _RailButton(
          icon: Icons.chat_bubble_outline_rounded,
          label: '$comments',
          onTap: onComments,
        ),
        const SizedBox(height: 14),
        ListenableBuilder(
          listenable: save,
          builder: (_, _) => _RailButton(
            icon: save.saved
                ? Icons.bookmark_rounded
                : Icons.bookmark_border_rounded,
            label: save.saved ? 'Saved' : 'Save',
            active: save.saved,
            onTap: onSave,
          ),
        ),
        const SizedBox(height: 14),
        _RailButton(
          icon: Icons.ios_share_rounded,
          label: 'Share',
          onTap: onShare,
        ),
      ],
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.onTap,
    this.label,
    this.active = false,
  });

  final IconData icon;
  final String? label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: active
                    ? AppTheme.volt
                    : Colors.black.withValues(alpha: 0.42),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              ),
              child: Icon(
                icon,
                size: 27,
                color: active ? AppTheme.ink : Colors.white,
              ),
            ),
            if (label != null) ...[
              const SizedBox(height: 4),
              Text(
                label!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  shadows: [Shadow(blurRadius: 4, color: Colors.black87)],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
