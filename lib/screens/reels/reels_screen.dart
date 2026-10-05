import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_events.dart';
import '../../core/errors.dart';
import '../../widgets/share_sheet.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/post.dart';
import '../../services/clip_cache.dart';
import '../../services/post_pager.dart';
import '../../services/post_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/like_button.dart';
import '../../core/hashtags.dart';
import '../../services/view_tracker.dart';
import '../../widgets/post_details_sheet.dart';
import '../../widgets/reel_actions.dart';
import '../../widgets/music_widgets.dart';
import '../../widgets/reel_photo.dart';
import '../../widgets/reel_progress.dart';
import '../../widgets/reel_video.dart';
import '../../widgets/save_controller.dart';
import '../../widgets/state_views.dart';
import '../post/comments_screen.dart';
import '../profile/profile_screen.dart';

/// Opens the Clips screen on top of everything, starting with [post] (used when someone taps a
/// video in Discover, on a profile or in a grid). Back returns to where they were.
void openClips(BuildContext context, Post post) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (ctx) => Scaffold(
        backgroundColor: Colors.black,
        body: ReelsScreen(
          active: true,
          initialPost: post,
          onBack: () => Navigator.of(ctx).maybePop(),
        ),
      ),
    ),
  );
}

/// Vertical feed of uploaded clips. Only the visible clip (and the next one,
/// preloaded) owns a native player.
class ReelsScreen extends StatefulWidget {
  const ReelsScreen({
    super.key,
    required this.active,
    required this.onBack,
    this.initialPost,
  });

  /// false while another tab is selected (stops playback).
  final bool active;

  /// Top-left back button.
  final VoidCallback onBack;

  /// Clip to start with (null = newest first).
  final Post? initialPost;

  @override
  State<ReelsScreen> createState() => _ReelsScreenState();
}

class _ReelsScreenState extends State<ReelsScreen> {
  late final PostPager _pager = PostPager(
    PostService.instance.videoQuery,
    pageSize: 8,
    first: widget.initialPost,
  );
  final PageController _pages = PageController();
  int _page = 0;
  bool _started = false;
  bool _wanting = false;

  @override
  void initState() {
    super.initState();
    AppEvents.feedRefresh.addListener(_refresh);
    _pager.addListener(_preload);
    // Warm-up: shortly after the app opens, the first clips are fetched quietly so the Clips
    // tab starts at once the first time.
    _warm = Timer(const Duration(seconds: 3), () {
      if (!mounted || _started || widget.active) return;
      _started = true;
      _pager.loadMore();
    });
  }

  Timer? _warm;

  @override
  void didUpdateWidget(ReelsScreen old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _preload();
  }

  /// Background preloading: while a clip plays, the next three are downloaded to the phone
  /// (several connections at once). When the user scrolls to them they start instantly.
  void _preload() {
    if (!_started) return;
    final posts = _pager.posts;
    final urls = <String>[];
    if (widget.active) {
      // the clip on screen first, then the next three
      for (var i = _page; i <= _page + 3 && i < posts.length; i++) {
        if (posts[i].isVideo) urls.add(posts[i].videoUrl);
      }
    } else if (_page == 0) {
      // warm-up while another tab is open: only the first two clips
      for (var i = 0; i < 2 && i < posts.length; i++) {
        if (posts[i].isVideo) urls.add(posts[i].videoUrl);
      }
      if (urls.isEmpty) return;
    } else {
      if (_wanting) {
        _wanting = false;
        ClipCache.instance.want(const []);
      }
      return;
    }
    _wanting = true;
    ClipCache.instance.want(urls);
  }

  void _refresh() {
    if (_started) _pager.refresh();
  }

  @override
  void dispose() {
    _warm?.cancel();
    AppEvents.feedRefresh.removeListener(_refresh);
    _pager.removeListener(_preload);
    if (_wanting) ClipCache.instance.want(const []);
    _pager.dispose();
    _pages.dispose();
    super.dispose();
  }

  Widget _withBack(Widget child) => Stack(
    fit: StackFit.expand,
    children: [
      child,
      SafeArea(
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 0, 0),
            child: ReelIconButton(
              icon: Icons.arrow_back_rounded,
              size: 28,
              onTap: widget.onBack,
            ),
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    // Lazy: do not hit Firestore until the Clips tab is first opened.
    if (widget.active && !_started) {
      _started = true;
      _pager.loadMore();
    }
    if (!_started) return const ColoredBox(color: Colors.black);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Theme(
        data: ThemeData.dark(useMaterial3: true),
        child: ColoredBox(
          color: Colors.black,
          child: ListenableBuilder(
            listenable: _pager,
            builder: (context, _) {
              if (_pager.initialLoading) {
                return _withBack(const CenteredLoader());
              }
              if (_pager.error != null && _pager.posts.isEmpty) {
                return _withBack(
                  ErrorState(error: _pager.error!, onRetry: _pager.retry),
                );
              }
              if (_pager.posts.isEmpty) {
                return _withBack(
                  const EmptyState(
                    icon: Icons.smart_display_outlined,
                    title: 'No clips yet',
                    subtitle:
                        'Tap + and choose Clips to upload the first video.',
                  ),
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
                      _preload();
                      if (i >= _pager.posts.length - 3) _pager.loadMore();
                    },
                    itemBuilder: (context, i) {
                      final post = _pager.posts[i];
                      return _ReelPage(
                        key: ValueKey(post.id),
                        post: post,
                        playing: widget.active && i == _page,
                        preload: widget.active && i == _page + 1,
                        onBack: widget.onBack,
                        onDeleted: () => _pager.removeById(post.id),
                      );
                    },
                  ),
                ),
              );
            },
          ),
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
    required this.onBack,
    required this.onDeleted,
  });

  final Post post;
  final bool playing;
  final bool preload;
  final VoidCallback onBack;
  final VoidCallback onDeleted;

  @override
  State<_ReelPage> createState() => _ReelPageState();
}

class _ReelPageState extends State<_ReelPage> {
  final ReelProgressHost _progress = ReelProgressHost();
  late final LikeController _like = LikeController(
    widget.post.id,
    widget.post.likeCount,
  );
  late final SaveController _save = SaveController(widget.post.id);
  late int _comments = widget.post.commentCount;
  VoidCallback? _unwatch;

  void _watch() {
    _unwatch?.call();
    _unwatch = widget.playing ? ViewTracker.instance.watch(widget.post) : null;
  }

  @override
  void initState() {
    super.initState();
    _watch();
  }

  @override
  void didUpdateWidget(_ReelPage old) {
    super.didUpdateWidget(old);
    if (old.playing != widget.playing || old.post.id != widget.post.id) {
      _watch();
    }
  }

  @override
  void dispose() {
    _unwatch?.call();
    _progress.dispose();
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
      await showShareSheet(context, widget.post);
    } catch (_) {
      if (mounted) showToast(context, 'Could not open the share menu.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final live = widget.playing || widget.preload;
    // The bottom bar is hidden on this screen, so only the phone's own gesture area is left.
    final inset = MediaQuery.of(context).padding.bottom;
    final bottom = inset + ReelProgressBar.hitHeight + 2;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (live)
          post.isPhotoClip
              ? ReelPhoto(
                  post: post,
                  play: widget.playing,
                  progress: _progress,
                  onDoubleTap: () => _like.setLiked(true),
                )
              : ReelVideo(
                  post: post,
                  play: widget.playing,
                  progress: _progress,
                  onDoubleTap: () => _like.setLiked(true),
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
          height: 300,
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

        // the progress line sits above the dark gradient, so it keeps its colour
        Positioned(
          left: 0,
          right: 0,
          bottom: inset,
          child: ReelProgressBar(host: _progress),
        ),

        // top: back, title, sound (plain icons, no backgrounds)
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Row(
                children: [
                  ReelIconButton(
                    icon: Icons.arrow_back_rounded,
                    size: 28,
                    onTap: widget.onBack,
                  ),
                  const Text(
                    'Clips',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                      shadows: kReelShadow,
                    ),
                  ),
                  const Spacer(),
                  ValueListenableBuilder<bool>(
                    valueListenable: ReelAudio.muted,
                    builder: (_, muted, _) => ReelIconButton(
                      icon: muted
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                      size: 28,
                      onTap: () => ReelAudio.muted.value = !muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // bottom: the action rail sits right above the author line, caption underneath
        Positioned(
          left: 0,
          right: 0,
          bottom: bottom,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _Rail(
                    like: _like,
                    save: _save,
                    comments: _comments,
                    onLike: _toggleLike,
                    onSave: _toggleSave,
                    onShare: _share,
                    onComments: () => showCommentsSheet(
                      context,
                      post: post,
                      onCountChanged: (d) {
                        if (mounted) setState(() => _comments += d);
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => openScreen(
                        context,
                        ProfileScreen(uid: post.authorId),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          UserAvatar(
                            url: post.authorPhotoUrl,
                            name: post.authorUsername,
                            radius: 17,
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
                                    color: Colors.white,
                                    shadows: kReelShadow,
                                  ),
                                ),
                                // the audio name goes right under the username
                                if (post.hasMusic)
                                  MusicLabel(musicId: post.musicId),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (post.caption.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      // the title: tap it for views, likes, date and everything else
                      GestureDetector(
                        key: const ValueKey('clipTitle'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => showPostDetails(context, post),
                        child: HashtagText(
                          post.caption,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          tagColor: AppTheme.volt,
                          style: const TextStyle(
                            color: Colors.white,
                            height: 1.3,
                            shadows: kReelShadow,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
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

  static const _heart = Color(0xFFFF3B5C);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListenableBuilder(
          listenable: like,
          builder: (_, _) => ReelIconButton(
            icon: like.liked
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            color: like.liked ? _heart : Colors.white,
            pop: like.liked,
            size: 34,
            label: '${like.count}',
            onTap: onLike,
          ),
        ),
        const SizedBox(height: 8),
        ReelIconButton(
          icon: Icons.chat_bubble_outline_rounded,
          label: '$comments',
          onTap: onComments,
        ),
        const SizedBox(height: 8),
        ListenableBuilder(
          listenable: save,
          builder: (_, _) => ReelIconButton(
            icon: save.saved
                ? Icons.bookmark_rounded
                : Icons.bookmark_border_rounded,
            color: save.saved ? AppTheme.volt : Colors.white,
            label: save.saved ? 'Saved' : 'Save',
            onTap: onSave,
          ),
        ),
        const SizedBox(height: 8),
        ReelIconButton(
          icon: Icons.ios_share_rounded,
          label: 'Share',
          onTap: onShare,
        ),
      ],
    );
  }
}
