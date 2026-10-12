import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/share.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../post/data/post_repository.dart';
import '../../post/presentation/comments_sheet.dart';
import '../../post/presentation/create_post_screen.dart';
import '../../post/presentation/create_sheet.dart';
import '../../post/presentation/post_menu.dart';
import '../../profile/data/user_repository.dart';

/// Full-screen vertical clips.
/// [clips] given -> play that list (from a profile / explore).
/// [clips] null  -> latest clips from everyone.
class ClipsScreen extends StatefulWidget {
  const ClipsScreen({super.key, this.clips, this.initialIndex = 0});

  final List<Post>? clips;
  final int initialIndex;

  @override
  State<ClipsScreen> createState() => _ClipsScreenState();
}

class _ClipsScreenState extends State<ClipsScreen> {
  late final PageController _pageCtrl = PageController(
    initialPage: widget.initialIndex < 0 ? 0 : widget.initialIndex,
  );
  late int _current = widget.initialIndex < 0 ? 0 : widget.initialIndex;
  bool _muted = false;
  final Set<String> _deleted = {};
  Stream<List<Post>>? _stream;

  @override
  void initState() {
    super.initState();
    if (widget.clips == null) {
      _stream = PostRepository.instance.recent(type: Post.clip, limit: 50);
    }
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  Widget _pager(List<Post> all) {
    final clips = all.where((c) => !_deleted.contains(c.id)).toList();
    if (clips.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const EmptyState(
              icon: Icons.smart_display_outlined,
              title: 'No clips yet',
              subtitle: 'Be the first to share a short video.',
            ),
            FilledButton.icon(
              onPressed: () => startCompose(context, ComposeMode.clip),
              icon: const Icon(Icons.videocam_outlined),
              label: const Text('Create clip'),
            ),
          ],
        ),
      );
    }
    return PageView.builder(
      controller: _pageCtrl,
      scrollDirection: Axis.vertical,
      itemCount: clips.length,
      onPageChanged: (i) => setState(() => _current = i),
      itemBuilder: (context, i) => ClipPlayer(
        key: ValueKey(clips[i].id),
        clip: clips[i],
        active: i == _current,
        muted: _muted,
        onToggleMute: () => setState(() => _muted = !_muted),
        onDeleted: () => setState(() => _deleted.add(clips[i].id)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 60,
                child: Row(
                  children: [
                    const SizedBox(width: 6),
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back, size: 28),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Clips',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'New clip',
                      onPressed: () => startCompose(context, ComposeMode.clip),
                      icon: const Icon(Icons.add_box_outlined, size: 26),
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
              ),
              Expanded(
                child: widget.clips != null
                    ? _pager(widget.clips!)
                    : StreamBuilder<List<Post>>(
                        stream: _stream,
                        builder: (context, snap) {
                          if (snap.hasError) {
                            return Center(child: ErrorView(error: snap.error));
                          }
                          if (!snap.hasData) return const LoadingView();
                          return _pager(snap.data!);
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ClipPlayer extends StatefulWidget {
  const ClipPlayer({
    super.key,
    required this.clip,
    required this.active,
    required this.muted,
    required this.onToggleMute,
    this.onDeleted,
  });

  final Post clip;
  final bool active;
  final bool muted;
  final VoidCallback onToggleMute;
  final VoidCallback? onDeleted;

  @override
  State<ClipPlayer> createState() => _ClipPlayerState();
}

class _ClipPlayerState extends State<ClipPlayer> {
  final _repo = PostRepository.instance;
  late final VideoPlayerController _ctrl;
  late final Stream<Post?> _live = _repo.watch(widget.clip.id);
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.clip.mediaUrl));
    _ctrl.setLooping(true);
    _ctrl.initialize().then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
      _ctrl.setVolume(widget.muted ? 0 : 1);
      if (widget.active) _play();
    }).catchError((Object _) {
      if (mounted) setState(() => _failed = true);
    });
  }

  void _play() {
    _ctrl.play();
    _repo.addView(widget.clip);
  }

  @override
  void didUpdateWidget(covariant ClipPlayer old) {
    super.didUpdateWidget(old);
    if (!_ready) return;
    if (widget.active != old.active) {
      widget.active ? _play() : _ctrl.pause();
    }
    if (widget.muted != old.muted) _ctrl.setVolume(widget.muted ? 0 : 1);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _togglePlay() {
    if (!_ready) return;
    setState(() => _ctrl.value.isPlaying ? _ctrl.pause() : _ctrl.play());
  }

  Future<void> _run(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  void _insights(Post c) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Clip insights',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text('Posted ${timeAgo(c.createdAt)} ago',
                  style: const TextStyle(color: AppColors.textSecondary)),
              const SizedBox(height: 16),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 2.2,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _Stat('Views', c.viewsCount, Icons.play_arrow_rounded),
                  _Stat('Likes', c.likesCount, Icons.favorite),
                  _Stat('Comments', c.commentsCount, Icons.chat_bubble),
                  _Stat('Reposts', c.repostsCount, Icons.repeat),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Post?>(
      stream: _live,
      initialData: widget.clip,
      builder: (context, snap) {
        final c = snap.data ?? widget.clip;
        final mine = c.authorId == UserRepository.instance.myUid;
        return Column(
          children: [
            Expanded(
              child: StreamBuilder<bool>(
                stream: _repo.isLiked(c.id),
                builder: (context, likeSnap) {
                  final liked = likeSnap.data ?? false;
                  return GestureDetector(
                    onTap: _togglePlay,
                    onDoubleTap: liked
                        ? null
                        : () => _run(() => _repo.setLiked(c, true)),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (!_ready) ClipCoverBackground(post: c),
                        if (_ready)
                          FittedBox(
                            fit: BoxFit.cover,
                            clipBehavior: Clip.hardEdge,
                            child: SizedBox(
                              width: _ctrl.value.size.width,
                              height: _ctrl.value.size.height,
                              child: VideoPlayer(_ctrl),
                            ),
                          ),
                        if (!_ready && !_failed)
                          const Center(child: CircularProgressIndicator()),
                        if (_failed)
                          const Center(
                            child: Text(
                              "Couldn't load this clip",
                              style: TextStyle(color: AppColors.textSecondary),
                            ),
                          ),
                        if (_ready && !_ctrl.value.isPlaying)
                          Center(
                            child: Icon(
                              Icons.play_arrow_rounded,
                              size: 90,
                              color: Colors.white.withValues(alpha: 0.8),
                            ),
                          ),
                        const Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: 160,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Colors.transparent, Color(0x88000000)],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 10,
                          bottom: 12,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _Action(
                                icon: liked
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                color: liked ? AppColors.like : Colors.white,
                                label: compactCount(c.likesCount),
                                onTap: () =>
                                    _run(() => _repo.setLiked(c, !liked)),
                              ),
                              _Action(
                                icon: Icons.chat_bubble_outline,
                                label: compactCount(c.commentsCount),
                                onTap: () => showComments(context, c),
                              ),
                              StreamBuilder<bool>(
                                stream: _repo.isReposted(c.id),
                                builder: (context, s) {
                                  final on = s.data ?? false;
                                  return _Action(
                                    icon: Icons.repeat,
                                    color: on ? AppColors.lime : Colors.white,
                                    label: compactCount(c.repostsCount),
                                    onTap: () =>
                                        _run(() => _repo.setReposted(c, !on)),
                                  );
                                },
                              ),
                              StreamBuilder<bool>(
                                stream: _repo.isSaved(c.id),
                                builder: (context, s) {
                                  final on = s.data ?? false;
                                  return _Action(
                                    icon: on
                                        ? Icons.bookmark
                                        : Icons.bookmark_border,
                                    color: on ? AppColors.lime : Colors.white,
                                    label: on ? 'Saved' : 'Save',
                                    onTap: () =>
                                        _run(() => _repo.setSaved(c, !on)),
                                  );
                                },
                              ),
                              _Action(
                                icon: Icons.ios_share,
                                label: 'Share',
                                onTap: () => sharePost(c),
                              ),
                              if (mine)
                                _Action(
                                  icon: Icons.auto_graph,
                                  label: 'Insights',
                                  onTap: () => _insights(c),
                                ),
                              _Action(
                                icon: widget.muted
                                    ? Icons.volume_off
                                    : Icons.volume_up,
                                label: widget.muted ? 'Unmute' : 'Mute',
                                onTap: widget.onToggleMute,
                              ),
                              _Action(
                                icon: Icons.more_horiz,
                                label: '',
                                onTap: () => showPostMenu(context, c,
                                    onDeleted: widget.onDeleted),
                              ),
                            ],
                          ),
                        ),
                        Positioned(
                          left: 16,
                          bottom: 18,
                          right: 90,
                          child: GestureDetector(
                            onTap: () {
                              _ctrl.pause();
                              openProfile(context, c.authorId);
                            },
                            child: Row(
                              children: [
                                Avatar(
                                    url: c.authorPhotoUrl,
                                    name: c.authorUsername,
                                    size: 40),
                                const SizedBox(width: 12),
                                Flexible(
                                  child: Text(
                                    c.authorUsername,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            if (c.caption.isNotEmpty)
              Container(
                width: double.infinity,
                color: Colors.black,
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Text(
                  c.caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            SizedBox(
              height: 4,
              child: _ready
                  ? VideoProgressIndicator(
                      _ctrl,
                      allowScrubbing: true,
                      padding: EdgeInsets.zero,
                      colors: const VideoProgressColors(
                        playedColor: AppColors.lime,
                        bufferedColor: Color(0xFF6B6E75),
                        backgroundColor: Color(0xFF3A3D44),
                      ),
                    )
                  : const ColoredBox(color: Color(0xFF3A3D44)),
            ),
          ],
        );
      },
    );
  }
}

class ClipCoverBackground extends StatelessWidget {
  const ClipCoverBackground({super.key, required this.post});
  final Post post;

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1E1B3A), Colors.black],
          ),
        ),
      );
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.icon);
  final String label;
  final int value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.lime),
          const SizedBox(width: 10),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(compactCount(value),
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w800)),
              Text(label,
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.white,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: SizedBox(
          width: 64,
          child: Column(
            children: [
              Icon(
                icon,
                size: 29,
                color: color,
                shadows: const [Shadow(blurRadius: 8, color: Colors.black54)],
              ),
              if (label.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
