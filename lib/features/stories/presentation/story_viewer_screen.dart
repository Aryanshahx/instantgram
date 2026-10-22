import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/services/app_settings.dart';
import '../../../core/services/hyper_intelligence.dart';
import '../../../core/services/music_player.dart';
import '../../../core/services/media_prefetch.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/face_effects.dart';
import '../../../shared/widgets/hi_blur.dart';
import '../../../shared/widgets/media_view.dart' show CutSkipper, MusicChip;
import '../../../shared/widgets/net_image.dart';
import '../../../shared/widgets/video_extras.dart';
import '../../editor/filters.dart';
import '../../profile/data/user_repository.dart';
import '../data/story_repository.dart';
import '../data/story_views.dart';
import 'story_extras.dart';
import '../../../core/services/video_cache.dart';
import '../../../shared/widgets/verified_badge.dart';
import '../../../shared/widgets/skeleton.dart';

/// Full-screen moment viewer: tap right = next, tap left = back,
/// hold = pause, swipe down = close. Plays photo and video moments.
class StoryViewerScreen extends StatefulWidget {
  const StoryViewerScreen({
    super.key,
    required this.groups,
    this.initialGroup = 0,
    this.recordViews = true,
    this.title,
  });

  final List<StoryGroup> groups;
  final int initialGroup;

  /// v0.15: false for highlights (no views, no "seen", no delete).
  final bool recordViews;

  /// v0.15: highlight name shown next to the username.
  final String? title;

  // v0.16 tests (no Firebase)
  @visibleForTesting
  static String? debugMe;
  @visibleForTesting
  static Future<void> Function(Story st)? debugRecordView;
  @visibleForTesting
  static Future<void> Function(Story st, bool liked)? debugLike;
  @visibleForTesting
  static Future<bool> Function(String storyId)? debugMyLike;
  @visibleForTesting
  static Stream<List<StoryView>> Function(String storyId)? debugViews;
  @visibleForTesting
  static Future<void> Function(Story st)? debugDelete;

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen>
    with SingleTickerProviderStateMixin {
  static const _photoTime = Duration(seconds: 5);

  /// v0.0.1: own copy, so a deleted moment leaves the viewer at once.
  late final List<StoryGroup> _groups = [
    for (final g in widget.groups) StoryGroup(g.authorId, [...g.stories]),
  ];
  late int _g = widget.initialGroup.clamp(0, _groups.length - 1);
  late int _s = widget.recordViews ? _firstUnseen(_groups[_g]) : 0;
  bool _deleting = false;
  late final AnimationController _timer =
      AnimationController(vsync: this, duration: _photoTime)
        ..addStatusListener((st) {
          if (st == AnimationStatus.completed) _next();
        });

  VideoPlayerController? _video;
  bool _videoReady = false;
  bool _videoError = false;
  bool _paused = false;

  /// v0.18: Hyper Intelligence blurred this moment (waits for "Tap to view").
  bool _hiBlocked = false;
  int _loadId = 0;

  StoryGroup get _group => _groups[_g];
  Story get _story => _group.stories[_s];

  String get _me => StoryViewerScreen.debugMe ?? UserRepository.instance.myUid;

  // v0.16: hearts on other people's moments
  final Map<String, bool> _liked = {};
  final Map<String, Future<void>> _viewSaved = {};
  static const String _kMusic = 'moment-music';

  int _firstUnseen(StoryGroup g) {
    final i = g.stories.indexWhere((s) => !AppSettings.instance.isSeen(s.id));
    return i < 0 ? 0 : i;
  }

  @override
  void initState() {
    super.initState();
    _show();
  }

  @override
  void dispose() {
    _timer.dispose();
    _video?.dispose();
    _hub?.dispose();
    MusicPlayer.instance.stop(_kMusic);
    super.dispose();
  }

  /// v0.16: saves the watch, then reads if I liked it before.
  void _recordView(Story st) {
    final save =
        (StoryViewerScreen.debugRecordView ??
        StoryRepository.instance.recordView)(st);
    _viewSaved[st.id] = save.catchError((Object _) {});
    if (_liked.containsKey(st.id)) return;
    save
        .then(
          (_) =>
              (StoryViewerScreen.debugMyLike ??
              StoryRepository.instance.myLike)(st.id),
        )
        .then((v) {
          if (mounted && !_liked.containsKey(st.id)) {
            setState(() => _liked[st.id] = v);
          }
        })
        .catchError((Object _) {});
  }

  Future<void> _toggleLike() async {
    final st = _story;
    final on = !(_liked[st.id] ?? false);
    setState(() => _liked[st.id] = on);
    try {
      await (_viewSaved[st.id] ?? Future<void>.value());
      await (StoryViewerScreen.debugLike ?? StoryRepository.instance.setLike)(
        st,
        on,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _liked[st.id] = !on);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text("Couldn't save your like")),
        );
    }
  }

  /// v0.16: music of the moment (loops while it is on screen).
  void _startMusic(Story st) {
    if (!st.hasMusic || _paused) return;
    MusicPlayer.instance.play(_kMusic, st.audioUrl, startMs: st.audioStartMs);
  }

  /// Start the current moment (photo timer or video).
  Future<void> _show() async {
    final id = ++_loadId;
    final st = _story;
    if (widget.recordViews) {
      AppSettings.instance.markSeen(st.id);
      // v0.15: every watch counts (rewatches too) — not for my own
      if (st.authorId != _me) _recordView(st);
    }
    MusicPlayer.instance.stop(_kMusic);
    _timer.stop();
    _timer.value = 0;
    final old = _video;
    _video = null;
    _videoReady = false;
    _videoError = false;
    old?.dispose();

    _photoReady = false;
    _prefetchNext();
    // v0.18 Hyper Intelligence: blurred until "Tap to view" (no timer,
    // no video, no music before)
    _hiBlocked = HyperIntelligence.instance.blursStory(st);
    if (_hiBlocked) {
      if (mounted) setState(() {});
      return;
    }
    if (!st.isVideo) {
      // v0.16: with music a photo stays 15 s
      _timer.duration = st.hasMusic
          ? const Duration(milliseconds: Story.musicPhotoMs)
          : _photoTime;
      if (mounted) setState(() {});
      // the 5 s only start when the photo is on screen
      await _loadPhoto(st.mediaUrl);
      if (!mounted || id != _loadId) return;
      _photoReady = true;
      if (!_paused) {
        _timer.forward(from: 0);
        _startMusic(st);
      }
      return;
    }

    if (mounted) setState(() {});
    final pooled = VideoPool.instance.take(st.mediaUrl);
    final c =
        pooled?.controller ??
        VideoCache.instance.controller(st.mediaUrl); // disk cache (v0.8)
    _video = c;
    try {
      await (pooled?.ready ?? c.initialize());
      if (!mounted || id != _loadId) return;
      final e = st.edits;
      final total = c.value.duration.inMilliseconds;
      // v0.12: removed parts (split + delete) are skipped
      final start = VideoTime.firstPlayable(
        e.trimStartMs,
        e.cuts,
      ).clamp(0, total);
      var end = e.trimEndMs > 0 ? e.trimEndMs.clamp(start, total) : total;
      end = VideoTime.playableEnd(end, e.cuts).clamp(start, total);
      if (VideoTime.playedMs(start, end, e.cuts) > kMomentMaxMs) {
        end = VideoTime.sourceAt(
          kMomentMaxMs,
          start,
          e.cuts,
        ).clamp(start, total);
      }
      final len = VideoTime.playedMs(
        start,
        end,
        e.cuts,
      ).clamp(1000, kMomentMaxMs);
      // v0.16: music replaces the video sound
      await c.setVolume(e.muted || st.hasMusic ? 0 : 1);
      if (start > 0) await c.seekTo(Duration(milliseconds: start));
      if (e.cuts.isNotEmpty) {
        final skipper = CutSkipper();
        c.addListener(() => skipper.check(c, e, startMs: start, endMs: end));
      }
      _timer.duration = Duration(milliseconds: len);
      setState(() => _videoReady = true);
      if (!_paused) {
        c.play();
        _timer.forward(from: 0);
        _startMusic(st);
      }
    } catch (_) {
      if (!mounted || id != _loadId) return;
      setState(() => _videoError = true);
      _timer.duration = const Duration(seconds: 3);
      _timer.forward(from: 0);
    }
  }

  bool _photoReady = false;

  /// Waits until the photo is downloaded + decoded (max 8 s).
  Future<void> _loadPhoto(String url) async {
    if (url.isEmpty || NetImage.disableCache) return;
    try {
      await precacheImage(
        CachedNetworkImageProvider(url),
        context,
      ).timeout(const Duration(seconds: 8));
    } catch (_) {
      // show it anyway; the timer must not get stuck
    }
  }

  /// Gets the moment after this one ready (photo or video).
  void _prefetchNext() {
    Story? next;
    if (_s < _group.stories.length - 1) {
      next = _group.stories[_s + 1];
    } else if (_g < _groups.length - 1) {
      final g = _groups[_g + 1];
      next = g.stories[_firstUnseen(g)];
    }
    if (next == null) return;
    if (next.isVideo) {
      VideoPool.instance.prefetch(next.mediaUrl);
    } else {
      MediaPrefetch.instance.image(next.mediaUrl);
    }
  }

  void _pause() {
    _paused = true;
    _timer.stop();
    _video?.pause();
    if (_story.hasMusic) MusicPlayer.instance.pause(_kMusic);
  }

  void _resume() {
    _paused = false;
    if (_story.isVideo && !_videoReady && !_videoError) return;
    if (!_story.isVideo && !_photoReady) return;
    _timer.forward();
    _video?.play();
    if (_story.hasMusic) {
      MusicPlayer.instance.isOwner(_kMusic)
          ? MusicPlayer.instance.resume(_kMusic)
          : _startMusic(_story);
    }
  }

  void _next() {
    if (_s < _group.stories.length - 1) {
      setState(() => _s++);
      _show();
    } else if (_g < _groups.length - 1) {
      setState(() {
        _g++;
        _s = widget.recordViews ? _firstUnseen(_group) : 0;
      });
      _show();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _prev() {
    if (_s > 0) {
      setState(() => _s--);
    } else if (_g > 0) {
      setState(() {
        _g--;
        _s = 0;
      });
    }
    _show();
  }

  // v0.15: who watched my moment
  // v0.16: ONE live list shared by the bar and the viewer list; a new
  // listener gets the newest list at once (before: stuck loading)
  LatestValue<List<StoryView>>? _hub;
  String _viewsFor = '';

  Stream<List<StoryView>> _viewsOf(Story st) {
    if (_hub == null || _viewsFor != st.id) {
      _hub?.dispose();
      _viewsFor = st.id;
      _hub = LatestValue(
        (StoryViewerScreen.debugViews ?? StoryRepository.instance.views)(st.id),
      );
    }
    return _hub!.stream;
  }

  Future<void> _openViewers() async {
    _pause();
    await showStoryViewers(context, _viewsOf(_story));
    if (mounted) _resume();
  }

  Future<void> _delete() async {
    _pause();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text(
          'Delete this moment?',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        content: const Text(
          'It will be gone for everyone.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: AppColors.like),
            ),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (ok != true) {
      _resume();
      return;
    }
    final st = _story;
    setState(() => _deleting = true);
    try {
      await (StoryViewerScreen.debugDelete ?? StoryRepository.instance.delete)(
        st,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text("Couldn't delete. Check your internet."),
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.fromLTRB(16, 0, 16, 84),
          ),
        );
      _resume();
      return;
    }
    if (!mounted) return;
    // v0.0.1: stay in the viewer and show the next moment
    final list = _group.stories;
    final i = list.indexWhere((x) => x.id == st.id);
    final atEnd = i < 0 || i == list.length - 1;
    if (atEnd && _g >= _groups.length - 1) {
      // nothing after it: close (the list is not changed while closing)
      _deleting = false;
      Navigator.of(context).maybePop();
      return;
    }
    list.removeAt(i);
    if (list.isEmpty) {
      _groups.removeAt(_g); // the next person moves into this place
      _s = widget.recordViews ? _firstUnseen(_group) : 0;
    } else if (_s >= list.length) {
      // it was the last one of this person: go on to the next person
      _g++;
      _s = widget.recordViews ? _firstUnseen(_group) : 0;
    }
    setState(() => _deleting = false);
    _show();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        // floats above the bottom bar (Delete stays free to tap)
        const SnackBar(
          content: Text('Moment deleted'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(16, 0, 16, 84),
        ),
      );
  }

  /// v0.0.1: round, easy to hit buttons (a near miss no longer skips).
  /// v0.0.1: plain X at the top right (no circle), big touch area.
  Widget _closeButton() => Tooltip(
    message: 'Close',
    child: GestureDetector(
      key: const ValueKey('story-close'),
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).maybePop(),
      child: const SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Icon(
            Icons.close_rounded,
            size: 28,
            color: Colors.white,
            shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
          ),
        ),
      ),
    ),
  );

  /// v0.0.1: Delete sits at the bottom of your own moment (icon over a
  /// small label), away from the X.
  Widget _deleteButton() => Tooltip(
    message: 'Delete moment',
    child: GestureDetector(
      key: const ValueKey('story-delete'),
      behavior: HitTestBehavior.opaque,
      onTap: _deleting ? null : _delete,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 60, minHeight: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: _deleting
                  ? const Padding(
                      padding: EdgeInsets.all(3),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(
                      Icons.delete_outline_rounded,
                      size: 24,
                      color: Colors.white,
                      shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                    ),
            ),
            const SizedBox(height: 3),
            const Text(
              'Delete',
              key: ValueKey('story-delete-label'),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _media() {
    final st = _story;
    if (!st.isVideo) return NetImage(st.mediaUrl, fit: BoxFit.contain);
    final c = _video;
    if (_videoError) {
      return const Center(
        child: Text(
          'Could not play this moment',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }
    if (c == null || !_videoReady) {
      return const LoadingSweep();
    }
    return Center(
      child: AspectRatio(
        aspectRatio: c.value.aspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            applyMatrix(st.edits.filter, VideoPlayer(c)),
            // v0.0.1 effects: face effect from the camera
            if (st.edits.face case final fx?)
              FaceFxLayer(fx: fx, controller: c),
            // v0.12: texts / stickers
            VideoOverlayLayer(overlays: st.edits.overlays, controller: c),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mine = _group.authorId == _me;
    final live = widget.recordViews;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: (d) {
          if (_deleting) return;
          final w =
              (context.findRenderObject() as RenderBox?)?.size.width ??
              MediaQuery.of(context).size.width;
          d.localPosition.dx < w / 3 ? _prev() : _next();
        },
        onLongPressStart: (_) => _pause(),
        onLongPressEnd: (_) => _resume(),
        onVerticalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v > 300) Navigator.of(context).maybePop();
          // v0.15: swipe up on my moment = viewer list
          if (v < -300 && mine && live) _openViewers();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_hiBlocked)
              HiBlur(
                key: const ValueKey('hi-moment'),
                imageUrl: _story.isVideo ? '' : _story.mediaUrl,
                onReveal: () {
                  HyperIntelligence.instance.revealStory(_story);
                  _show();
                },
              )
            else
              _media(),
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 140,
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
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 4, 0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        for (var i = 0; i < _group.stories.length; i++)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: AnimatedBuilder(
                                  animation: _timer,
                                  builder: (context, _) =>
                                      LinearProgressIndicator(
                                        minHeight: 3,
                                        value: i < _s
                                            ? 1
                                            : i == _s
                                            ? _timer.value
                                            : 0,
                                        backgroundColor: Colors.white24,
                                        color: Colors.white,
                                      ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () {
                            final uid = _group.authorId;
                            final nav = Navigator.of(context);
                            nav.pop();
                            openProfile(nav.context, uid);
                          },
                          child: Avatar(
                            url: _group.photoUrl,
                            photoUid: _group.authorId,
                            name: _group.username,
                            size: 36,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: NameBadge(
                            _group.username,
                            uid: _group.authorId,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (widget.title != null) ...[
                          Flexible(
                            child: Text(
                              widget.title!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          timeAgo(_story.createdAt),
                          style: const TextStyle(color: Colors.white70),
                        ),
                        if (_story.isVideo && _story.edits.muted) ...[
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.volume_off,
                            size: 16,
                            color: Colors.white70,
                          ),
                        ],
                        const Spacer(),
                        _closeButton(),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            // v0.16: music name
            if (_story.hasMusic)
              Positioned(
                left: 14,
                bottom: mine && live ? 70 : 22,
                right: 80,
                child: SafeArea(
                  top: false,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: MusicChip(
                      key: const ValueKey('story-music'),
                      name: _story.audioName,
                    ),
                  ),
                ),
              ),
            // v0.16: heart on someone else's moment
            if (!mine && live)
              Positioned(
                right: 10,
                bottom: 8,
                child: SafeArea(
                  top: false,
                  child: IconButton(
                    key: const ValueKey('story-like'),
                    tooltip: 'Like',
                    iconSize: 30,
                    onPressed: _toggleLike,
                    icon: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      transitionBuilder: (c, a) =>
                          ScaleTransition(scale: a, child: c),
                      child: (_liked[_story.id] ?? false)
                          ? const Icon(
                              Icons.favorite,
                              key: ValueKey('story-liked'),
                              color: AppColors.like,
                            )
                          : const Icon(
                              Icons.favorite_border,
                              key: ValueKey('story-unliked'),
                              color: Colors.white,
                            ),
                    ),
                  ),
                ),
              ),
            if (mine && live)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  // v0.0.1: seen by on the left, Delete on the right
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 6, 8),
                    child: Row(
                      children: [
                        SeenByBar(
                          key: ValueKey('seen-${_story.id}'),
                          views: _viewsOf(_story),
                          onTap: _openViewers,
                        ),
                        const Spacer(),
                        _deleteButton(),
                      ],
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
