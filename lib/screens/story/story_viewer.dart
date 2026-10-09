import 'package:flutter/material.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:video_player/video_player.dart';

import '../../core/app_events.dart';
import '../../core/errors.dart';
import '../../core/story_images.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/highlight.dart';
import '../../models/music.dart';
import '../../models/story.dart';
import '../../services/highlight_service.dart';
import '../../services/music_player.dart';
import '../../services/story_service.dart';
import '../../services/story_views.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/highlights.dart';
import '../../widgets/like_button.dart'
    show kSuperHeartColor, showSuperHeartBurst;
import '../../widgets/music_widgets.dart';
import '../../widgets/sensitive_gate.dart';
import '../../widgets/story_overlays.dart';
import '../../widgets/story_viewers_sheet.dart';

class StoryViewer extends StatefulWidget {
  const StoryViewer({
    super.key,
    required this.groups,
    required this.initialIndex,
    this.highlight,
  });

  final List<StoryGroup> groups;
  final int initialIndex;

  /// Playing a highlight: no views are counted, and delete takes the moment out of it.
  final Highlight? highlight;

  @override
  State<StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends State<StoryViewer> {
  late final PageController _pc = PageController(
    initialPage: widget.initialIndex,
  );

  @override
  void initState() {
    super.initState();
    StoryViews.instance.newVisit(); // watching again later counts as a rewatch
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _nextGroup() {
    final page = (_pc.page ?? 0).round();
    if (page < widget.groups.length - 1) {
      _pc.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      Navigator.of(context).pop();
    }
  }

  void _previousGroup() {
    final page = (_pc.page ?? 0).round();
    if (page > 0) {
      _pc.previousPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView.builder(
        controller: _pc,
        itemCount: widget.groups.length,
        itemBuilder: (context, i) => _GroupPlayer(
          key: ValueKey(widget.groups[i].authorId),
          group: widget.groups[i],
          nextFirstUrl: i + 1 < widget.groups.length
              ? widget.groups[i + 1].stories.first.coverUrl
              : null,
          onFinished: _nextGroup,
          onBackFromFirst: _previousGroup,
          onClose: () => Navigator.of(context).pop(),
          highlight: widget.highlight,
        ),
      ),
    );
  }
}

class _GroupPlayer extends StatefulWidget {
  const _GroupPlayer({
    super.key,
    required this.group,
    this.nextFirstUrl,
    required this.onFinished,
    required this.onBackFromFirst,
    required this.onClose,
    this.highlight,
  });

  final StoryGroup group;
  final Highlight? highlight;

  /// First picture of the next person's moments (loaded in advance).
  final String? nextFirstUrl;
  final VoidCallback onFinished;
  final VoidCallback onBackFromFirst;
  final VoidCallback onClose;

  @override
  State<_GroupPlayer> createState() => _GroupPlayerState();
}

class _GroupPlayerState extends State<_GroupPlayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 5),
  );
  int _i = 0;
  bool _loaded = false; // the picture is ready: only then the 5 seconds start
  bool _failed = false;
  bool _holding = false;
  bool _started = false;
  VideoPlayerController? _vc;
  MusicPlayer? _music;
  int _gen = 0;

  bool get _mine => widget.group.authorId == UserService.instance.myUid;
  late Highlight? _hl = widget.highlight;
  Story get _story => widget.group.stories[_i];

  @override
  void initState() {
    super.initState();
    _anim.addStatusListener((s) {
      if (s == AnimationStatus.completed) _next();
    });
    sensitiveTick.addListener(_onReveal);
  }

  /// Flagged by the photo check: blurred and paused until "Tap to view".
  bool get _blurred => isBlurred(_story.id, _story.authorId, _story.sensitive);

  void _onReveal() {
    if (!_blurred) _resume();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _prepare();
  }

  Future<void> _stopMedia() async {
    final v = _vc;
    final m = _music;
    _vc = null;
    _music = null;
    await v?.dispose();
    await m?.dispose();
  }

  /// Loads the current moment (photo, or video), then starts its timer. The next ones load
  /// meanwhile.
  Future<void> _prepare() async {
    final gen = ++_gen;
    final story = _story;
    if (_loaded || _failed) {
      setState(() {
        _loaded = false;
        _failed = false;
      });
    }
    _anim.stop();
    _anim.value = 0;
    await _stopMedia();
    if (!mounted || gen != _gen) return;
    _anim.duration = Duration(seconds: story.seconds);
    var failed = false;
    VideoPlayerController? vc;
    MusicPlayer? mp;
    try {
      if (story.isVideo) {
        vc = VideoPlayerController.networkUrl(
          Uri.parse(story.videoUrl),
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
        );
        await vc.initialize();
        await vc.setVolume(story.keepSound ? 1 : 0);
        final ms = vc.value.duration.inMilliseconds;
        if (ms > 0) {
          _anim.duration = Duration(
            milliseconds: ms.clamp(1000, kMaxStorySeconds * 1000 + 1500),
          );
        }
      } else {
        await precacheImage(
          storyImageProvider(context, story.imageUrl),
          context,
        );
      }
    } catch (_) {
      failed = true;
      await vc?.dispose();
      vc = null;
    }
    final track = musicById(story.musicId);
    if (!failed && track != null) {
      mp = MusicPlayer(track);
      await mp.init(volume: story.musicVolume);
    }
    if (!mounted || gen != _gen) {
      await vc?.dispose();
      await mp?.dispose();
      return;
    }
    _vc = vc;
    _music = mp;
    setState(() {
      _loaded = true;
      _failed = failed;
    });
    if (!failed && !_mine && _hl == null) {
      StoryViews.instance.record(story);
      _loadLike(story, gen);
    }
    if (!_holding && !_blurred) {
      _anim.forward(from: 0);
      _vc?.play();
      _music?.play();
    }
    // warm the next picture (this person's, or the next person's first)
    if (_i + 1 < widget.group.stories.length) {
      warmStoryImage(context, widget.group.stories[_i + 1].coverUrl);
      if (_i + 2 < widget.group.stories.length) {
        warmStoryImage(context, widget.group.stories[_i + 2].coverUrl);
      }
    } else if (widget.nextFirstUrl != null) {
      warmStoryImage(context, widget.nextFirstUrl!);
    }
  }

  @override
  void dispose() {
    sensitiveTick.removeListener(_onReveal);
    _gen++;
    _anim.dispose();
    _vc?.dispose();
    _music?.dispose();
    super.dispose();
  }

  Widget _media(Story story) {
    final c = _vc;
    if (story.isVideo && c != null && c.value.isInitialized) {
      return FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: c.value.size.width,
          height: c.value.size.height,
          child: VideoPlayer(c),
        ),
      );
    }
    return Image(
      key: ValueKey(story.id),
      image: storyImageProvider(context, story.coverUrl),
      fit: BoxFit.contain,
      gaplessPlayback: true,
    );
  }

  void _next() {
    if (_i < widget.group.stories.length - 1) {
      setState(() => _i++);
      _prepare();
    } else {
      widget.onFinished();
    }
  }

  void _previous() {
    if (_i > 0) {
      setState(() => _i--);
      _prepare();
    } else {
      widget.onBackFromFirst();
      _prepare();
    }
  }

  void _pause() {
    _anim.stop();
    _vc?.pause();
    _music?.pause();
  }

  void _resume() {
    if (mounted && _loaded && !_holding && !_blurred) {
      _anim.forward();
      _vc?.play();
      _music?.play();
    }
  }

  /// My live moment: put it in a highlight too (it stays there after 48 h).
  Future<void> _toHighlight() async {
    _pause();
    final h = await pickHighlight(context);
    if (h != null && mounted) {
      try {
        await HighlightService.instance.addStory(h, _story);
        if (mounted) showToast(context, 'Added to "${h.title}"');
      } catch (e) {
        if (mounted) showToast(context, friendlyError(e));
      }
    }
    _resume();
  }

  Future<void> _delete() async {
    _pause();
    final hl = _hl;
    final ok = await confirm(
      context,
      title: hl != null ? 'Remove from "${hl.title}"?' : 'Delete moment?',
      confirmLabel: hl != null ? 'Remove' : 'Delete',
      destructive: true,
    );
    if (!ok) {
      if (mounted && _loaded) {
        _anim.forward();
        _vc?.play();
        _music?.play();
      }
      return;
    }
    try {
      if (hl != null) {
        _hl = await HighlightService.instance.remove(hl, _story.id);
      } else {
        await StoryService.instance.deleteStory(_story);
      }
      widget.group.stories.removeAt(_i);
      AppEvents.refreshFeed();
      if (widget.group.stories.isEmpty) {
        widget.onClose();
        return;
      }
      if (_i >= widget.group.stories.length) {
        _i = widget.group.stories.length - 1;
      }
      if (mounted) _prepare();
    } catch (e) {
      if (mounted) {
        showToast(context, friendlyError(e));
        if (_loaded) _anim.forward();
      }
    }
  }

  // ------------------------------------------------------------------ likes

  bool _liked = false;
  bool _super = false;
  bool _likeBusy = false;

  Future<void> _loadLike(Story story, int gen) async {
    if (_liked || _super) setState(() => _liked = _super = false);
    try {
      final r = await StoryViews.instance.likeOf(story);
      if (!mounted || gen != _gen) return;
      setState(() {
        _liked = r.liked || r.superHeart;
        _super = r.superHeart;
      });
    } catch (_) {
      // the heart stays empty
    }
  }

  /// Tap the heart: like / unlike.
  Future<void> _toggleLike() async {
    if (_likeBusy) return;
    final story = _story;
    final was = (_liked, _super);
    final like = !_liked;
    setState(() {
      _liked = like;
      if (!like) _super = false;
    });
    _likeBusy = true;
    try {
      await StoryViews.instance.setLike(story, liked: like);
    } catch (_) {
      if (mounted) {
        setState(() {
          _liked = was.$1;
          _super = was.$2;
        });
        showToast(context, 'Could not save. Try again.');
      }
    } finally {
      _likeBusy = false;
    }
  }

  /// Hold the heart: a super heart (once per moment).
  Future<void> _sendSuper() async {
    if (_likeBusy) return;
    if (_super) {
      showToast(context, 'You already sent a super heart here.');
      return;
    }
    final story = _story;
    final was = (_liked, _super);
    showSuperHeartBurst(context);
    setState(() {
      _liked = true;
      _super = true;
    });
    _likeBusy = true;
    try {
      await StoryViews.instance.setLike(story, liked: true, superHeart: true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _liked = was.$1;
          _super = was.$2;
        });
        showToast(context, 'Could not send. Try again.');
      }
    } finally {
      _likeBusy = false;
    }
  }

  Widget _heart() => Positioned(
    right: 8,
    bottom: 8,
    child: SafeArea(
      child: Tooltip(
        message: 'Like · hold for a super heart',
        child: GestureDetector(
          key: const ValueKey('storyLike'),
          behavior: HitTestBehavior.opaque,
          onTap: _toggleLike,
          onLongPress: _sendSuper,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(
              _liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              size: 32,
              color: _super
                  ? kSuperHeartColor
                  : (_liked ? const Color(0xFFFF3B5C) : Colors.white),
              shadows: const [Shadow(blurRadius: 8, color: Colors.black54)],
            ),
          ),
        ),
      ),
    ),
  );

  /// My own moment: who watched it (the moment waits meanwhile).
  Future<void> _viewers() async {
    _anim.stop();
    _vc?.pause();
    _music?.pause();
    await showStoryViewers(context, _story.id, collection: _story.collection);
    if (mounted && _loaded && !_holding) {
      _anim.forward();
      _vc?.play();
      _music?.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final story = _story;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) {
        final w = MediaQuery.of(context).size.width;
        if (d.localPosition.dx < w / 3) {
          _previous();
        } else {
          _next();
        }
      },
      onLongPressStart: (_) {
        _holding = true;
        _anim.stop();
        _vc?.pause();
        _music?.pause();
      },
      onLongPressEnd: (_) {
        _holding = false;
        if (_loaded) {
          _anim.forward();
          _vc?.play();
          _music?.play();
        }
      },
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 300) widget.onClose();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!_loaded)
            const Center(child: CircularProgressIndicator(strokeWidth: 2))
          else if (_failed)
            const Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: Colors.white54,
                size: 48,
              ),
            )
          else
            SensitiveGate(
              id: story.id,
              authorId: story.authorId,
              sensitive: story.sensitive,
              child: StoryCanvas(
                media: _media(story),
                overlays: story.overlays,
              ),
            ),
          if (!_mine && _hl == null && _loaded && !_failed) _heart(),
          if (_mine && _hl == null)
            Positioned(
              right: 12,
              bottom: 12,
              child: SafeArea(
                child: TextButton.icon(
                  key: const ValueKey('storyToHighlight'),
                  style: TextButton.styleFrom(
                    backgroundColor: Colors.black45,
                    foregroundColor: Colors.white,
                    shape: const StadiumBorder(),
                  ),
                  onPressed: _toHighlight,
                  icon: const Icon(Icons.favorite_border_rounded, size: 20),
                  label: const Text(
                    'Highlight',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
          if (_mine && _hl == null)
            Positioned(
              left: 12,
              bottom: 12,
              child: SafeArea(
                child: TextButton.icon(
                  key: const ValueKey('storyViewers'),
                  style: TextButton.styleFrom(
                    backgroundColor: Colors.black45,
                    foregroundColor: Colors.white,
                    shape: const StadiumBorder(),
                  ),
                  onPressed: _viewers,
                  icon: const Icon(Icons.visibility_outlined, size: 20),
                  label: const Text(
                    'Viewers',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      for (var k = 0; k < widget.group.stories.length; k++)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: k < _i
                                  ? const LinearProgressIndicator(
                                      value: 1,
                                      minHeight: 3,
                                      color: Colors.white,
                                      backgroundColor: Colors.white24,
                                    )
                                  : k == _i
                                  ? AnimatedBuilder(
                                      animation: _anim,
                                      builder: (_, _) =>
                                          LinearProgressIndicator(
                                            value: _anim.value,
                                            minHeight: 3,
                                            color: Colors.white,
                                            backgroundColor: Colors.white24,
                                          ),
                                    )
                                  : const LinearProgressIndicator(
                                      value: 0,
                                      minHeight: 3,
                                      color: Colors.white,
                                      backgroundColor: Colors.white24,
                                    ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      UserAvatar(
                        url: widget.group.photoUrl,
                        name: widget.group.username,
                        radius: 16,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    widget.group.username,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  timeago.format(
                                    story.createdAt,
                                    locale: 'en_short',
                                  ),
                                  style: const TextStyle(color: Colors.white70),
                                ),
                              ],
                            ),
                            if (story.limited || story.spotlight)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (story.spotlight)
                                      const Padding(
                                        padding: EdgeInsets.only(right: 6),
                                        child: Icon(
                                          Icons.auto_awesome_rounded,
                                          key: ValueKey('viewerSpotlight'),
                                          size: 14,
                                          color: AppTheme.volt,
                                        ),
                                      ),
                                    if (story.limited) ...[
                                      const Icon(
                                        Icons.group_rounded,
                                        key: ValueKey('viewerLimited'),
                                        size: 14,
                                        color: AppTheme.volt,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        // the list name is only for the author
                                        _mine && story.listName.isNotEmpty
                                            ? story.listName
                                            : 'List',
                                        style: const TextStyle(
                                          color: AppTheme.volt,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            if (story.musicId.isNotEmpty)
                              MusicLabel(musicId: story.musicId),
                          ],
                        ),
                      ),
                      const Spacer(),
                      if (_mine)
                        IconButton(
                          key: const ValueKey('storyDelete'),
                          tooltip: _hl != null
                              ? 'Remove from highlight'
                              : 'Delete',
                          onPressed: _delete,
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.white,
                          ),
                        ),
                      IconButton(
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close, color: Colors.white),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
