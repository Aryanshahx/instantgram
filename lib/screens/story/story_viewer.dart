import 'package:flutter/material.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:video_player/video_player.dart';

import '../../core/app_events.dart';
import '../../core/errors.dart';
import '../../core/story_images.dart';
import '../../core/ui.dart';
import '../../models/music.dart';
import '../../models/story.dart';
import '../../services/music_player.dart';
import '../../services/story_service.dart';
import '../../services/story_views.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/music_widgets.dart';
import '../../widgets/story_overlays.dart';
import '../../widgets/story_viewers_sheet.dart';

class StoryViewer extends StatefulWidget {
  const StoryViewer({
    super.key,
    required this.groups,
    required this.initialIndex,
  });

  final List<StoryGroup> groups;
  final int initialIndex;

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
  });

  final StoryGroup group;

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
  Story get _story => widget.group.stories[_i];

  @override
  void initState() {
    super.initState();
    _anim.addStatusListener((s) {
      if (s == AnimationStatus.completed) _next();
    });
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
    if (!failed && !_mine) StoryViews.instance.record(story);
    if (!_holding) {
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

  Future<void> _delete() async {
    _anim.stop();
    _vc?.pause();
    _music?.pause();
    final ok = await confirm(
      context,
      title: 'Delete moment?',
      confirmLabel: 'Delete',
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
      await StoryService.instance.deleteStory(_story);
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

  /// My own moment: who watched it (the moment waits meanwhile).
  Future<void> _viewers() async {
    _anim.stop();
    _vc?.pause();
    _music?.pause();
    await showStoryViewers(context, _story.id);
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
            StoryCanvas(media: _media(story), overlays: story.overlays),
          if (_mine)
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
                            if (story.musicId.isNotEmpty)
                              MusicLabel(musicId: story.musicId),
                          ],
                        ),
                      ),
                      const Spacer(),
                      if (_mine)
                        IconButton(
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
