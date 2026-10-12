import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../../core/services/app_settings.dart';
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
///
/// Gestures on the video:
///  * tap = pause / play, double tap = like
///  * hold = 2x speed, hold + move finger up/down = volume
///  * swipe up = next clip (top bar hides), swipe down = previous (top bar shows)
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
  double _volume = 1;
  bool _showTopBar = true;
  int _count = 0;
  final Set<String> _deleted = {};
  Stream<List<Post>>? _stream;

  @override
  void initState() {
    super.initState();
    if (widget.clips == null) {
      _stream = PostRepository.instance.recent(type: Post.clip, limit: 50);
    }
    AppSettings.instance.load();
    // warm up the profile copy so the first like is instant
    UserRepository.instance.meCached().ignore();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  void _onPageChanged(int i) {
    setState(() {
      if (i > _current) _showTopBar = false; // swiped up -> hide
      if (i < _current) _showTopBar = true; // swiped down -> show
      _current = i;
    });
  }

  void _next() {
    if (!_pageCtrl.hasClients || _current >= _count - 1) return;
    _pageCtrl.animateToPage(
      _current + 1,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  void _toggleMute() => setState(() {
        if (_muted) {
          _muted = false;
          if (_volume < 0.05) _volume = 1;
        } else {
          _muted = true;
        }
      });

  void _setVolume(double v) => setState(() {
        _volume = v;
        _muted = v < 0.01;
      });

  Widget _pager(List<Post> all) {
    final clips = all.where((c) => !_deleted.contains(c.id)).toList();
    _count = clips.length;
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
    return ValueListenableBuilder<bool>(
      valueListenable: AppSettings.instance.clipsAutoScroll,
      builder: (context, autoScroll, child) => PageView.builder(
        controller: _pageCtrl,
        scrollDirection: Axis.vertical,
        itemCount: clips.length,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, i) => ClipPlayer(
          key: ValueKey(clips[i].id),
          clip: clips[i],
          active: i == _current,
          muted: _muted,
          volume: _volume,
          autoScroll: autoScroll,
          onToggleMute: _toggleMute,
          onVolumeChanged: _setVolume,
          onFinished: _next,
          onDeleted: () => setState(() => _deleted.add(clips[i].id)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: SafeArea(
                top: false,
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
            ),
            // Back button + "Clips" — hides when you swipe up.
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: IgnorePointer(
                ignoring: !_showTopBar,
                child: AnimatedSlide(
                  offset: _showTopBar ? Offset.zero : const Offset(0, -1),
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  child: AnimatedOpacity(
                    opacity: _showTopBar ? 1 : 0,
                    duration: const Duration(milliseconds: 220),
                    child: SafeArea(
                      bottom: false,
                      child: SizedBox(
                        height: 52,
                        child: Row(
                          children: [
                            const SizedBox(width: 4),
                            IconButton(
                              tooltip: 'Back',
                              onPressed: () => Navigator.of(context).maybePop(),
                              icon: const Icon(
                                Icons.arrow_back,
                                size: 24,
                                shadows: [
                                  Shadow(blurRadius: 8, color: Colors.black54),
                                ],
                              ),
                            ),
                            const Text(
                              'Clips',
                              style: TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.4,
                                shadows: [
                                  Shadow(blurRadius: 8, color: Colors.black54),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
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
    this.volume = 1,
    this.autoScroll = false,
    this.onVolumeChanged,
    this.onFinished,
    this.onDeleted,
  });

  final Post clip;
  final bool active;
  final bool muted;
  final double volume;
  final bool autoScroll;
  final VoidCallback onToggleMute;
  final ValueChanged<double>? onVolumeChanged;
  final VoidCallback? onFinished;
  final VoidCallback? onDeleted;

  @override
  State<ClipPlayer> createState() => _ClipPlayerState();
}

/// Instant on/off: shows the new state right away, then trusts the server.
class _Optimistic {
  bool? _value;

  bool show(bool server) => _value ?? server;

  int count(int serverCount, bool server) {
    final v = _value;
    if (v == null || v == server) return serverCount;
    final n = serverCount + (v ? 1 : -1);
    return n < 0 ? 0 : n;
  }
}

class _ClipPlayerState extends State<ClipPlayer>
    with SingleTickerProviderStateMixin {
  final _repo = PostRepository.instance;
  late final VideoPlayerController _ctrl;
  late final Stream<Post?> _live = _repo.watch(widget.clip.id);
  late final Stream<bool> _likedStream = _repo.isLiked(widget.clip.id);
  late final Stream<bool> _repostedStream = _repo.isReposted(widget.clip.id);
  late final Stream<bool> _savedStream = _repo.isSaved(widget.clip.id);
  final _like = _Optimistic();
  final _repost = _Optimistic();
  final _save = _Optimistic();

  bool _ready = false;
  bool _failed = false;
  bool _finishedSent = false;
  bool _detailsOpen = false;

  // hold gestures
  bool _fast = false; // 2x speed
  bool _volumeMode = false;
  bool _wasPlaying = false;
  double _volumeAtStart = 1;

  // double-tap heart
  late final AnimationController _heart = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  double get _effectiveVolume => widget.muted ? 0 : widget.volume;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.clip.mediaUrl));
    _ctrl.setLooping(!widget.autoScroll);
    _ctrl.addListener(_onTick);
    _ctrl.initialize().then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
      _ctrl.setVolume(_effectiveVolume);
      if (widget.active) _play();
    }).catchError((Object _) {
      if (mounted) setState(() => _failed = true);
    });
  }

  void _play() {
    final v = _ctrl.value;
    if (v.duration > Duration.zero && v.position >= v.duration) {
      _ctrl.seekTo(Duration.zero);
    }
    _finishedSent = false;
    _ctrl.play();
    _repo.addView(widget.clip);
  }

  /// Auto scroll: tell the screen when this clip has ended.
  void _onTick() {
    if (!widget.autoScroll || !widget.active || _finishedSent) return;
    final v = _ctrl.value;
    if (!v.isInitialized || v.duration <= Duration.zero) return;
    final ended = !v.isPlaying &&
        v.position >= v.duration - const Duration(milliseconds: 250);
    if (ended) {
      _finishedSent = true;
      widget.onFinished?.call();
    }
  }

  @override
  void didUpdateWidget(covariant ClipPlayer old) {
    super.didUpdateWidget(old);
    if (widget.autoScroll != old.autoScroll) {
      _ctrl.setLooping(!widget.autoScroll);
      _finishedSent = false;
    }
    if (!_ready) return;
    if (widget.active != old.active) {
      if (widget.active) {
        _play();
      } else {
        _ctrl.pause();
        _ctrl.setPlaybackSpeed(1);
      }
    }
    if (widget.muted != old.muted || widget.volume != old.volume) {
      _ctrl.setVolume(_effectiveVolume);
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onTick);
    _ctrl.dispose();
    _heart.dispose();
    super.dispose();
  }

  // ---------------- gestures ----------------

  void _togglePlay() {
    if (!_ready) return;
    setState(() => _ctrl.value.isPlaying ? _ctrl.pause() : _play());
  }

  void _holdStart(LongPressStartDetails d) {
    if (!_ready) return;
    HapticFeedback.lightImpact();
    _wasPlaying = _ctrl.value.isPlaying;
    _volumeAtStart = _effectiveVolume;
    _ctrl.setPlaybackSpeed(2);
    if (!_wasPlaying) _ctrl.play();
    setState(() {
      _fast = true;
      _volumeMode = false;
    });
  }

  void _holdMove(LongPressMoveUpdateDetails d) {
    if (!_ready) return;
    final dy = d.offsetFromOrigin.dy;
    if (!_volumeMode) {
      if (dy.abs() < 18) return;
      // finger moved up/down -> volume mode (normal speed)
      _ctrl.setPlaybackSpeed(1);
      setState(() {
        _fast = false;
        _volumeMode = true;
      });
    }
    // 220 px of finger movement = full volume range. Up = louder.
    final v = (_volumeAtStart - dy / 220).clamp(0.0, 1.0);
    widget.onVolumeChanged?.call(v);
  }

  void _holdEnd() {
    if (!_ready) return;
    _ctrl.setPlaybackSpeed(1);
    if (!_wasPlaying) _ctrl.pause();
    setState(() {
      _fast = false;
      _volumeMode = false;
    });
  }

  // ---------------- actions ----------------

  Future<void> _toggle(
    _Optimistic o,
    bool newValue,
    Future<void> Function() save,
  ) async {
    setState(() => o._value = newValue);
    try {
      await save();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => o._value = null);
    }
  }

  void _doubleTapLike(Post c, bool liked) {
    _heart.forward(from: 0);
    HapticFeedback.lightImpact();
    if (!liked) _toggle(_like, true, () => _repo.setLiked(c, true));
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Post?>(
      stream: _live,
      initialData: widget.clip,
      builder: (context, snap) {
        final c = snap.data ?? widget.clip;
        return Column(
          children: [
            Expanded(child: _videoArea(c)),
            _CaptionBar(
              post: c,
              open: _detailsOpen,
              onTap: () => setState(() => _detailsOpen = !_detailsOpen),
            ),
            SizedBox(
              height: 3,
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

  Widget _videoArea(Post c) {
    return StreamBuilder<bool>(
      stream: _likedStream,
      builder: (context, likeSnap) {
        final likedServer = likeSnap.data ?? false;
        final liked = _like.show(likedServer);
        return Stack(
          fit: StackFit.expand,
          children: [
            // 1) the video + its gestures (bottom layer)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _togglePlay,
              onDoubleTap: () => _doubleTapLike(c, liked),
              onLongPressStart: _holdStart,
              onLongPressMoveUpdate: _holdMove,
              onLongPressEnd: (_) => _holdEnd(),
              onLongPressCancel: _holdEnd,
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
                ],
              ),
            ),
            // 2) things that never catch touches
            IgnorePointer(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: 120,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x66000000), Colors.transparent],
                        ),
                      ),
                    ),
                  ),
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 180,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Color(0x99000000)],
                        ),
                      ),
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
                  if (_ready && !_ctrl.value.isPlaying && !_fast)
                    Center(
                      child: Icon(
                        Icons.play_arrow_rounded,
                        size: 80,
                        color: Colors.white.withValues(alpha: 0.8),
                      ),
                    ),
                  if (_fast)
                    const Positioned(
                      top: 64,
                      left: 0,
                      right: 0,
                      child: Center(child: _SpeedPill()),
                    ),
                  if (_volumeMode)
                    Center(
                      child: _VolumeHud(value: _effectiveVolume),
                    ),
                  Center(child: _HeartBurst(animation: _heart)),
                ],
              ),
            ),
            // 3) buttons (top layer — no double-tap delay)
            Positioned(
              right: 6,
              bottom: 10,
              child: _actions(c, liked, likedServer),
            ),
            Positioned(
              left: 14,
              bottom: 14,
              right: 80,
              child: Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _ctrl.pause();
                    openProfile(context, c.authorId);
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Avatar(
                        url: c.authorPhotoUrl,
                        name: c.authorUsername,
                        size: 34,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          c.authorUsername,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            shadows: [
                              Shadow(blurRadius: 6, color: Colors.black54),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _actions(Post c, bool liked, bool likedServer) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Action(
          icon: liked ? Icons.favorite : Icons.favorite_border,
          color: liked ? AppColors.like : Colors.white,
          label: compactCount(_like.count(c.likesCount, likedServer)),
          onTap: () => _toggle(_like, !liked, () => _repo.setLiked(c, !liked)),
        ),
        _Action(
          icon: Icons.chat_bubble_outline,
          label: compactCount(c.commentsCount),
          onTap: () => showComments(context, c),
        ),
        StreamBuilder<bool>(
          stream: _repostedStream,
          builder: (context, s) {
            final server = s.data ?? false;
            final on = _repost.show(server);
            return _Action(
              icon: Icons.repeat,
              color: on ? AppColors.lime : Colors.white,
              label: compactCount(_repost.count(c.repostsCount, server)),
              onTap: () =>
                  _toggle(_repost, !on, () => _repo.setReposted(c, !on)),
            );
          },
        ),
        StreamBuilder<bool>(
          stream: _savedStream,
          builder: (context, s) {
            final on = _save.show(s.data ?? false);
            return _Action(
              icon: on ? Icons.bookmark : Icons.bookmark_border,
              color: on ? AppColors.lime : Colors.white,
              label: on ? 'Saved' : 'Save',
              onTap: () => _toggle(_save, !on, () => _repo.setSaved(c, !on)),
            );
          },
        ),
        _Action(
          icon: Icons.ios_share,
          label: 'Share',
          onTap: () => sharePost(c),
        ),
        _Action(
          icon: widget.muted ? Icons.volume_off : Icons.volume_up,
          label: widget.muted ? 'Unmute' : 'Mute',
          onTap: widget.onToggleMute,
        ),
        _Action(
          icon: Icons.more_horiz,
          label: '',
          onTap: () => showPostMenu(
            context,
            c,
            onDeleted: widget.onDeleted,
            showAutoScroll: true,
          ),
        ),
      ],
    );
  }
}

/// Caption under the video. Tap -> full caption + details.
class _CaptionBar extends StatelessWidget {
  const _CaptionBar({
    required this.post,
    required this.open,
    required this.onTap,
  });

  final Post post;
  final bool open;
  final VoidCallback onTap;

  /// Caption with #hashtags in lime.
  static TextSpan _captionSpan(String text) {
    final spans = <TextSpan>[];
    final re = RegExp(r'#[\p{L}\p{M}\p{N}_]+', unicode: true);
    var last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      spans.add(TextSpan(
        text: m.group(0),
        style: const TextStyle(
          color: AppColors.lime,
          fontWeight: FontWeight.w600,
        ),
      ));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return TextSpan(children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final hasCaption = post.caption.isNotEmpty;
    final maxOpen = MediaQuery.of(context).size.height * 0.4;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: Container(
          width: double.infinity,
          color: Colors.black,
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: open
              ? ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxOpen),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '@${post.authorUsername}',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const Icon(Icons.keyboard_arrow_down,
                                size: 20, color: AppColors.textSecondary),
                          ],
                        ),
                        if (hasCaption) ...[
                          const SizedBox(height: 6),
                          Text.rich(
                            _captionSpan(post.caption),
                            style: const TextStyle(fontSize: 14.5, height: 1.4),
                          ),
                        ],
                        const SizedBox(height: 10),
                        _detail(Icons.schedule,
                            'Posted ${fullDate(post.createdAt)}'),
                        _detail(Icons.favorite_border,
                            _plural(post.likesCount, 'like')),
                        _detail(Icons.chat_bubble_outline,
                            _plural(post.commentsCount, 'comment')),
                        _detail(Icons.repeat,
                            _plural(post.repostsCount, 'repost')),
                      ],
                    ),
                  ),
                )
              : Row(
                  children: [
                    Expanded(
                      child: hasCaption
                          ? Text.rich(
                              _captionSpan(post.caption),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14.5),
                            )
                          : Text(
                              'Posted ${timeAgo(post.createdAt)}'
                              '${timeAgo(post.createdAt) == 'now' ? '' : ' ago'}',
                              style: const TextStyle(
                                fontSize: 13.5,
                                color: AppColors.textSecondary,
                              ),
                            ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'more',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  static String _plural(int n, String word) =>
      '${compactCount(n)} $word${n == 1 ? '' : 's'}';

  Widget _detail(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: [
            Icon(icon, size: 15, color: AppColors.textSecondary),
            const SizedBox(width: 8),
            Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      );
}

class _SpeedPill extends StatelessWidget {
  const _SpeedPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '2x',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          ),
          SizedBox(width: 4),
          Icon(Icons.fast_forward_rounded, size: 18),
        ],
      ),
    );
  }
}

class _VolumeHud extends StatelessWidget {
  const _VolumeHud({required this.value});
  final double value;

  @override
  Widget build(BuildContext context) {
    final icon = value < 0.01
        ? Icons.volume_off
        : value < 0.5
            ? Icons.volume_down
            : Icons.volume_up;
    return Container(
      width: 64,
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 120,
            width: 8,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Color(0x55FFFFFF)),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      heightFactor: value,
                      widthFactor: 1,
                      child: const ColoredBox(color: AppColors.lime),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Icon(icon, size: 20),
          const SizedBox(height: 2),
          Text(
            '${(value * 100).round()}%',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _HeartBurst extends StatelessWidget {
  const _HeartBurst({required this.animation});
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = animation.value;
        if (t == 0 || t == 1) return const SizedBox.shrink();
        final scale = t < 0.3 ? 0.6 + t / 0.3 * 0.6 : 1.2 - (t - 0.3) * 0.3;
        final opacity = t < 0.7 ? 1.0 : (1 - (t - 0.7) / 0.3);
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.scale(scale: scale, child: child),
        );
      },
      child: const Icon(
        Icons.favorite,
        size: 96,
        color: AppColors.like,
        shadows: [Shadow(blurRadius: 16, color: Colors.black45)],
      ),
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

/// Right-side action button: shrinks a little the moment you touch it.
class _Action extends StatefulWidget {
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
  State<_Action> createState() => _ActionState();
}

class _ActionState extends State<_Action> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.82 : 1,
        duration: const Duration(milliseconds: 90),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: SizedBox(
            width: 52,
            child: Column(
              children: [
                Icon(
                  widget.icon,
                  size: 25,
                  color: widget.color,
                  shadows: const [Shadow(blurRadius: 8, color: Colors.black54)],
                ),
                if (widget.label.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    widget.label,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
