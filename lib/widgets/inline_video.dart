import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import '../core/clip_focus.dart';
import '../models/finish.dart';
import '../models/post.dart';
import '../services/clip_cache.dart';
import '../services/music_player.dart';
import 'overlay_tools.dart';

/// Sound switch for clips that play inside the Discover feed (starts silent, like Instagram).
class InlineAudio {
  static final ValueNotifier<bool> muted = ValueNotifier<bool>(true);
}

/// Where a clip is on the screen.
class InlineSpot {
  const InlineSpot(this.id, this.top, this.height);
  final String id;
  final double top;
  final double height;
}

/// The clip that should play: it has to be mostly visible (60% of it, or 45% of the screen for
/// very tall clips); if several qualify, the one closest to the middle of the screen wins.
String? pickInlineActive(
  Iterable<InlineSpot> spots, {
  required double viewTop,
  required double viewBottom,
}) {
  String? best;
  var bestDistance = double.infinity;
  final mid = (viewTop + viewBottom) / 2;
  for (final s in spots) {
    if (s.height <= 0) continue;
    final bottom = s.top + s.height;
    final visible =
        (bottom < viewBottom ? bottom : viewBottom) -
        (s.top > viewTop ? s.top : viewTop);
    if (visible <= 0) continue;
    final need = (s.height * 0.6) < (viewBottom - viewTop) * 0.45
        ? s.height * 0.6
        : (viewBottom - viewTop) * 0.45;
    if (visible < need) continue;
    final d = (s.top + s.height / 2 - mid).abs();
    if (d < bestDistance) {
      bestDistance = d;
      best = s.id;
    }
  }
  return best;
}

/// What the hub needs from a clip in the feed.
abstract class InlineHost {
  /// Where the clip is now; null when it can not play (hidden or not laid out).
  InlineSpot? spot();

  MediaQueryData? media();
}

/// Keeps track of every clip in the feed and decides which single one plays.
class InlineVideoHub {
  InlineVideoHub._() {
    // A clips screen opened on top of the feed stops the clip that plays here.
    ClipFocus.instance.version.addListener(poke);
  }
  static final InlineVideoHub instance = InlineVideoHub._();

  final ValueNotifier<String?> active = ValueNotifier<String?>(null);
  final Set<InlineHost> _items = {};
  bool _scheduled = false;

  /// false while the app is in the background
  bool resumed = true;

  void register(InlineHost s) => _items.add(s);

  void unregister(InlineHost s) {
    _items.remove(s);
    poke();
  }

  /// Asks for a re-check after the next frame (cheap to call often).
  void poke() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _evaluate();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  void _evaluate() {
    // quiet while the app is in the background, and while a clips screen is open
    if (!resumed || ClipFocus.instance.anyOpen) {
      active.value = null;
      return;
    }
    final spots = <InlineSpot>[];
    double top = 0;
    double bottom = 0;
    for (final s in _items) {
      final spot = s.spot();
      if (spot == null) continue;
      spots.add(spot);
      final mq = s.media();
      if (mq != null) {
        top = mq.padding.top + 48;
        bottom = mq.size.height - 56;
      }
    }
    active.value = spots.isEmpty
        ? null
        : pickInlineActive(spots, viewTop: top, viewBottom: bottom);
  }
}

/// The player that lies on top of a clip's thumbnail in the feed. It only exists while its clip
/// is the one the hub picked, so at most one native player is alive in the feed.
///
/// It also plays the music of a photo post (no video, only the speaker button): [videoUrl] is
/// then empty. For a video inside a carousel [videoUrl] is that video's address; swiping to
/// another page changes it while the music keeps playing.
class InlineVideoLayer extends StatefulWidget {
  const InlineVideoLayer({
    super.key,
    required this.post,
    this.showSound = true,
    this.videoUrl,
    this.finish,
  });
  final Post post;
  final bool showSound;

  /// Texts and look of the video shown (null = the post's own).
  final MediaFinish? finish;

  /// null = the post's own video; '' = no video (music only).
  final String? videoUrl;

  @override
  State<InlineVideoLayer> createState() => _InlineVideoLayerState();
}

class _InlineVideoLayerState extends State<InlineVideoLayer>
    with WidgetsBindingObserver
    implements InlineHost {
  final InlineVideoHub _hub = InlineVideoHub.instance;
  VideoPlayerController? _c;
  MusicPlayer? _music;
  bool _ready = false;
  bool _ticking = true;
  int _gen = 0;
  Timer? _startTimer;
  ScrollPosition? _pos;

  String get _url => widget.videoUrl ?? widget.post.videoUrl;
  bool get _hasVideo => _url.isNotEmpty;
  bool get _hasSpeaker => _hasVideo || widget.post.hasMusic;

  @override
  void initState() {
    super.initState();
    _hub.register(this);
    _hub.active.addListener(_onActive);
    InlineAudio.muted.addListener(_applyVolume);
    WidgetsBinding.instance.addObserver(this);
    _hub.poke();
  }

  @override
  void didUpdateWidget(InlineVideoLayer old) {
    super.didUpdateWidget(old);
    final oldUrl = old.videoUrl ?? old.post.videoUrl;
    if (oldUrl != _url && _ready) _swapVideo();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ignore: deprecated_member_use
    _ticking = TickerMode.of(
      context,
    ); // false when the feed is hidden (other tab or screen)
    final pos = Scrollable.maybeOf(context)?.position;
    if (pos != _pos) {
      _pos?.removeListener(_hub.poke);
      _pos = pos;
      _pos?.addListener(_hub.poke);
    }
    _hub.poke();
  }

  @override
  MediaQueryData? media() => mounted ? MediaQuery.maybeOf(context) : null;

  @override
  InlineSpot? spot() {
    if (!mounted || !_ticking || !_hasSpeaker) return null;
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
    final top = ro.localToGlobal(Offset.zero).dy;
    return InlineSpot(widget.post.id, top, ro.size.height);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _hub.resumed = state == AppLifecycleState.resumed;
    _hub.poke();
  }

  void _onActive() {
    final on = _hub.active.value == widget.post.id;
    if (on) {
      if (!_ready && _startTimer == null) {
        // wait a moment so a quick fling past the clip does not start a player
        _startTimer = Timer(const Duration(milliseconds: 350), () {
          _startTimer = null;
          if (mounted && _hub.active.value == widget.post.id) _start();
        });
      }
    } else {
      _startTimer?.cancel();
      _startTimer = null;
      if (_c != null || _ready) _stop();
    }
  }

  Future<VideoPlayerController?> _openVideo(Post post, String url) async {
    final opts = post.hasMusic ? VideoPlayerOptions(mixWithOthers: true) : null;
    final File? local = ClipCache.instance.cached(url);
    final c = local != null
        ? VideoPlayerController.file(local, videoPlayerOptions: opts)
        : VideoPlayerController.networkUrl(
            Uri.parse(url),
            videoPlayerOptions: opts,
          );
    try {
      await c.initialize();
      await c.setLooping(true);
      return c;
    } catch (_) {
      await c.dispose();
      return null;
    }
  }

  Future<void> _start() async {
    final gen = ++_gen;
    final post = widget.post;
    final url = _url;
    VideoPlayerController? c;
    MusicPlayer? music;
    if (url.isNotEmpty) {
      c = await _openVideo(post, url);
      if (c == null) return;
    }
    final track = post.playableMusic;
    if (track != null) {
      music = MusicPlayer(track);
      await music.init();
    }
    if (!mounted || gen != _gen || _hub.active.value != post.id) {
      await c?.dispose();
      await music?.dispose();
      return;
    }
    c?.addListener(_onTick);
    setState(() {
      _c = c;
      _music = music;
      _ready = true;
    });
    _applyVolume();
    await c?.play();
    await _music?.play();
  }

  /// The page of a carousel changed: another video (or none) while the music goes on.
  Future<void> _swapVideo() async {
    final gen = ++_gen;
    final old = _c;
    old?.removeListener(_onTick);
    setState(() => _c = null);
    await old?.dispose();
    final url = _url;
    if (url.isEmpty) {
      _applyVolume();
      return;
    }
    final c = await _openVideo(widget.post, url);
    if (c == null) return;
    if (!mounted || gen != _gen || _hub.active.value != widget.post.id) {
      await c.dispose();
      return;
    }
    c.addListener(_onTick);
    setState(() => _c = c);
    _lastPos = Duration.zero;
    _applyVolume();
    await c.play();
  }

  Duration _lastPos = Duration.zero;
  void _onTick() {
    final c = _c;
    if (c == null) return;
    final pos = c.value.position;
    if (pos + const Duration(seconds: 1) < _lastPos) _music?.restart();
    _lastPos = pos;
  }

  void _applyVolume() {
    final v = (InlineAudio.muted.value || !widget.showSound) ? 0.0 : 1.0;
    final post = widget.post;
    _c?.setVolume(post.hasMusic && !post.keepSound ? 0 : v);
    _music?.setVolume(v * post.musicVolume);
  }

  void _stop() {
    _gen++;
    final c = _c;
    final m = _music;
    _c = null;
    _music = null;
    c?.removeListener(_onTick);
    c?.dispose();
    m?.dispose();
    if (mounted) setState(() => _ready = false);
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _hub.active.removeListener(_onActive);
    InlineAudio.muted.removeListener(_applyVolume);
    _pos?.removeListener(_hub.poke);
    _hub.unregister(this);
    _gen++;
    _c?.removeListener(_onTick);
    _c?.dispose();
    _music?.dispose();
    super.dispose();
  }

  Widget _speaker() => Positioned(
    right: 10,
    bottom: 10,
    child: ValueListenableBuilder<bool>(
      valueListenable: InlineAudio.muted,
      builder: (_, muted, _) => GestureDetector(
        key: const ValueKey('inlineSound'),
        behavior: HitTestBehavior.opaque,
        onTap: () => InlineAudio.muted.value = !muted,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            color: Colors.white,
            size: 24,
            shadows: const [Shadow(blurRadius: 8, color: Colors.black87)],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final showVideo = _ready && c != null && _hasVideo;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (showVideo)
          // touches go through to what is below (the carousel is swiped over a playing video)
          IgnorePointer(
            child: ColoredBox(
              color: Colors.black,
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: c.value.size.width,
                  height: c.value.size.height,
                  child: FinishedMedia(
                    finish: widget.videoUrl == null
                        ? widget.post.finish
                        : widget.finish,
                    player: c,
                    child: VideoPlayer(c),
                  ),
                ),
              ),
            ),
          ),
        // the speaker is always there for a photo with music (it is how people turn the music on)
        if (widget.showSound &&
            (showVideo || (!_hasVideo && widget.post.hasMusic)))
          _speaker(),
      ],
    );
  }
}
