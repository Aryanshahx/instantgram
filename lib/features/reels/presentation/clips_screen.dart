import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../../core/services/app_settings.dart';
import '../../../core/services/content_filter.dart';
import '../../../core/services/media_prefetch.dart';
import '../../../core/services/music_player.dart';
import '../../../core/services/net_quality.dart';
import '../../../core/services/system_volume.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/share.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/media_view.dart';
import '../../../shared/widgets/net_image.dart';
import '../../../shared/widgets/seek_bar.dart';
import '../../post/data/post_repository.dart';
import '../data/clips_warmup.dart';
import '../../post/presentation/comments_sheet.dart';
import '../../post/presentation/create_sheet.dart';
import '../../post/presentation/post_menu.dart';
import '../../profile/data/user_repository.dart';

/// Full-screen vertical clips.
/// [clips] given -> play that list (from a profile / explore).
/// [clips] null  -> latest clips from everyone.
///
/// Gestures on the video:
///  * tap = pause / play, double tap = like
///  * hold = 2x speed, hold + move finger up/down = phone media volume
///  * swipe up = next clip (top bar hides), swipe down = previous (top bar shows)
class ClipsScreen extends StatefulWidget {
  const ClipsScreen({
    super.key,
    this.clips,
    this.initialIndex = 0,
    this.source,
  });

  final List<Post>? clips;
  final int initialIndex;

  /// Where the clips were opened from (Analytics). null = Clips tab.
  final String? source;

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
    SystemVolume.instance.get().then((v) {
      if (mounted) setState(() => _volume = v);
    });
    // warm up the profile copy so the first like is instant
    UserRepository.instance.meCached().ignore();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  /// Gets the next clips ready while you watch this one
  /// (next 2 videos opened, next 3 covers downloaded).
  void _prefetch(List<Post> clips, int i) {
    MediaPrefetch.instance.ahead(
      clips,
      i,
      images: 3,
      videos: 2,
      mixWithOthers: (p) => p.hasMusic,
    );
  }

  List<Post> _visible = const [];
  int _prefetchedFor = -1;

  void _onPageChanged(int i) {
    _prefetch(_visible, i);
    _prefetchedFor = i;
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

  void _toggleMute() => setState(() => _muted = !_muted);

  /// Changes the PHONE media volume (like the volume buttons).
  void _setVolume(double v) {
    SystemVolume.instance.set(v);
    setState(() {
      _volume = v;
      if (v > 0.01) _muted = false;
    });
  }

  Widget _pager(List<Post> all) {
    final clips = all.where((c) => !_deleted.contains(c.id)).toList();
    _count = clips.length;
    _visible = clips;
    if (_prefetchedFor != _current && clips.isNotEmpty) {
      _prefetchedFor = _current;
      final at = _current;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _prefetch(clips, at);
      });
    }
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
          source:
              widget.source ??
              (widget.clips == null ? ViewSource.clips : ViewSource.other),
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
                        initialData: ClipsWarmup.instance.latest,
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
    this.source = ViewSource.clips,
  });

  final Post clip;

  /// Where it is watched (for Analytics).
  final String source;
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

  /// Player for the current item when it is a video (else null).
  VideoPlayerController? _ctrl;
  late final Stream<Post?> _live = _repo.watch(widget.clip.id);
  late final Stream<bool> _likedStream = _repo.isLiked(widget.clip.id);
  late final Stream<bool> _repostedStream = _repo.isReposted(widget.clip.id);
  late final Stream<bool> _savedStream = _repo.isSaved(widget.clip.id);
  final _like = _Optimistic();
  final _repost = _Optimistic();
  final _save = _Optimistic();
  final PageController _itemPages = PageController();

  /// Current photo / video inside this clip.
  int _item = 0;
  late final List<MediaItem> _items = widget.clip.items;

  bool _ready = false;
  bool _failed = false;
  bool _finishedSent = false;
  bool _detailsOpen = false;
  Timer? _photoTimer;

  // adaptive quality (small copy while the network is slow)
  bool _usingLow = false;
  StallWatch? _stall;
  Timer? _startTimer;

  // watch time of the current video (for the author's Analytics)
  int _maxWatch = 0;
  bool _completed = false;

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

  MediaItem get _cur => _items[_item.clamp(0, _items.length - 1)];
  bool get _isVideo => _cur.isVideo;
  String get _musicOwner => 'clip-${widget.clip.id}';

  /// Player volume: the phone volume does the rest.
  /// Music replaces the video sound.
  double get _effectiveVolume =>
      (widget.muted || _edits.muted || widget.clip.hasMusic) ? 0 : 1;

  VideoEdits get _edits => _cur.edits;
  int _startMs = 0;
  int _endMs = 0; // 0 = until the end

  /// Manual loop when trimmed, auto scroll or more items follow.
  bool get _manualLoop =>
      widget.autoScroll || _edits.hasTrim || _items.length > 1;

  @override
  void initState() {
    super.initState();
    _openItem();
    if (widget.active) _startActive();
  }

  /// Prepares the current item (video player or photo).
  void _openItem() {
    _ready = false;
    _failed = false;
    _finishedSent = false;
    _photoTimer?.cancel();
    if (!_isVideo) {
      _ready = true;
      return;
    }
    if (kDisableVideoPlayback) return;
    // full quality, unless videos were buffering a moment ago
    _usingLow = NetQuality.slow && _cur.lowUrl.isNotEmpty;
    final url = _usingLow ? _cur.lowUrl : _cur.url;
    // ready player from the prefetch pool = instant start
    final pooled = VideoPool.instance.take(
      url,
      mixWithOthers: widget.clip.hasMusic,
    );
    final c = pooled?.controller ?? _newCtrl(url);
    _ctrl = c;
    c.setLooping(!_manualLoop);
    c.addListener(_onTick);
    _watchStall(c);
    // first frame takes too long -> try the small copy
    _startTimer?.cancel();
    _startTimer = Timer(NetQuality.startTimeout, () {
      if (mounted && _ctrl == c && !_ready && widget.active) _switchToLow();
    });
    (pooled?.ready ?? c.initialize())
        .then((_) async {
          if (!mounted || _ctrl != c) return;
          _applyTrim(c);
          if (_startMs > 0) await c.seekTo(Duration(milliseconds: _startMs));
          if (!mounted || _ctrl != c) return;
          setState(() => _ready = true);
          c.setVolume(_effectiveVolume);
          if (widget.active) _play();
        })
        .catchError((Object _) {
          if (!mounted || _ctrl != c) return;
          if (!_usingLow && _cur.lowUrl.isNotEmpty) {
            _switchToLow();
          } else {
            setState(() => _failed = true);
          }
        });
  }

  VideoPlayerController _newCtrl(String url) =>
      VideoPlayerController.networkUrl(
        Uri.parse(url),
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: widget.clip.hasMusic,
        ),
      );

  void _applyTrim(VideoPlayerController c) {
    final total = c.value.duration.inMilliseconds;
    _startMs = _edits.trimStartMs.clamp(0, total);
    _endMs = _edits.trimEndMs > _startMs ? _edits.trimEndMs.clamp(0, total) : 0;
  }

  void _watchStall(VideoPlayerController c) {
    _stall?.dispose();
    _stall = null;
    if (_usingLow || _cur.lowUrl.isEmpty) return;
    _stall = StallWatch(c, onStall: _switchToLow);
  }

  /// Buffering: continue with the smaller copy at the same moment.
  Future<void> _switchToLow() async {
    final old = _ctrl;
    final item = _item;
    final low = _cur.lowUrl;
    if (old == null || _usingLow || low.isEmpty) return;
    _usingLow = true;
    NetQuality.markSlow();
    _stall?.dispose();
    _stall = null;
    final c = _newCtrl(low);
    try {
      await c.initialize();
    } catch (_) {
      c.dispose();
      return;
    }
    if (!mounted || _ctrl != old || _item != item) {
      c.dispose();
      return;
    }
    final wasReady = _ready;
    final playing = !wasReady || old.value.isPlaying;
    final pos = wasReady ? old.value.position : Duration.zero;
    _applyTrim(c);
    await c.setLooping(!_manualLoop);
    final at = pos.inMilliseconds > _startMs
        ? pos
        : Duration(milliseconds: _startMs);
    if (at > Duration.zero) await c.seekTo(at);
    if (!mounted || _ctrl != old) {
      c.dispose();
      return;
    }
    await c.setVolume(_effectiveVolume);
    old.removeListener(_onTick);
    c.addListener(_onTick);
    setState(() {
      _ctrl = c;
      _ready = true;
      _failed = false;
    });
    if (widget.active && playing) {
      _play();
      if (_fast) c.setPlaybackSpeed(2);
    }
    old.dispose();
  }

  /// Frees the current video player (and reports watch time).
  void _closeItem() {
    _photoTimer?.cancel();
    _startTimer?.cancel();
    _stall?.dispose();
    _stall = null;
    final c = _ctrl;
    _ctrl = null;
    if (c != null) {
      c.removeListener(_onTick);
      c.dispose();
    }
    _sendWatch();
  }

  void _sendWatch() {
    if (_maxWatch > 0 || _completed) {
      _repo.reportWatch(widget.clip, watchMs: _maxWatch, completed: _completed);
    }
    _maxWatch = 0;
    _completed = false;
  }

  void _goToItem(int i) {
    if (i == _item || i < 0 || i >= _items.length) return;
    setState(() {
      _closeItem();
      _item = i;
      _openItem();
    });
    if (widget.active && !_isVideo) _startPhotoTimer();
  }

  /// Clip came on screen.
  void _startActive() {
    _repo.addView(widget.clip, source: widget.source);
    if (widget.clip.hasMusic) {
      MusicPlayer.instance.play(
        _musicOwner,
        widget.clip.audioUrl,
        volume: widget.muted ? 0 : 1,
      );
    }
    if (_isVideo) {
      if (_ready) _play();
    } else {
      _startPhotoTimer();
    }
  }

  /// Auto scroll: photos stay 5 seconds.
  void _startPhotoTimer() {
    _photoTimer?.cancel();
    if (!widget.autoScroll) return;
    _photoTimer = Timer(const Duration(seconds: 5), _itemFinished);
  }

  /// Current item ended (auto scroll): next item, or next clip.
  void _itemFinished() {
    if (!mounted || !widget.active) return;
    if (_item < _items.length - 1) {
      _itemPages.animateToPage(
        _item + 1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else if (widget.autoScroll) {
      _finishedSent = true;
      widget.onFinished?.call();
    }
  }

  int get _endOrTotal {
    final c = _ctrl;
    if (c == null) return 0;
    return _endMs > 0 ? _endMs : c.value.duration.inMilliseconds;
  }

  void _play() {
    final c = _ctrl;
    if (c == null) return;
    final v = c.value;
    final pos = v.position.inMilliseconds;
    if (v.duration > Duration.zero &&
        (pos >= _endOrTotal - 50 || pos < _startMs - 50)) {
      c.seekTo(Duration(milliseconds: _startMs));
    }
    _finishedSent = false;
    c.play();
  }

  /// End of the (trimmed) video: loop, next item, or next clip.
  void _onTick() {
    final c = _ctrl;
    if (c == null) return;
    final v = c.value;
    if (!v.isInitialized || v.duration <= Duration.zero) return;
    final pos = v.position.inMilliseconds;
    final watched = pos - _startMs;
    if (watched > _maxWatch) _maxWatch = watched;
    if (!_manualLoop || !widget.active || _finishedSent) return;
    final atEnd =
        pos >= _endOrTotal - 120 ||
        (!v.isPlaying && pos >= v.duration.inMilliseconds - 250);
    if (!atEnd) return;
    _completed = true;
    final more = _item < _items.length - 1;
    if (widget.autoScroll || more) {
      _finishedSent = true;
      c.pause();
      if (more) {
        _itemPages.animateToPage(
          _item + 1,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      } else {
        widget.onFinished?.call();
      }
    } else {
      c.seekTo(Duration(milliseconds: _startMs));
      if (!v.isPlaying) c.play();
    }
  }

  @override
  void didUpdateWidget(covariant ClipPlayer old) {
    super.didUpdateWidget(old);
    final c = _ctrl;
    if (widget.autoScroll != old.autoScroll) {
      c?.setLooping(!_manualLoop);
      _finishedSent = false;
      if (widget.active && !_isVideo) _startPhotoTimer();
    }
    if (widget.active != old.active) {
      if (widget.active) {
        _startActive();
      } else {
        _photoTimer?.cancel();
        c?.pause();
        c?.setPlaybackSpeed(1);
        _sendWatch();
        if (widget.clip.hasMusic) MusicPlayer.instance.stop(_musicOwner);
      }
    }
    if (widget.muted != old.muted) {
      c?.setVolume(_effectiveVolume);
      if (widget.clip.hasMusic && widget.active) {
        MusicPlayer.instance.setVolume(widget.muted ? 0 : 1);
      }
    }
  }

  @override
  void dispose() {
    _closeItem();
    if (widget.clip.hasMusic) MusicPlayer.instance.stop(_musicOwner);
    _itemPages.dispose();
    _heart.dispose();
    super.dispose();
  }

  // ---------------- gestures ----------------

  void _togglePlay() {
    final c = _ctrl;
    if (!_ready || c == null) return;
    setState(() => c.value.isPlaying ? c.pause() : _play());
  }

  void _holdStart(LongPressStartDetails d) {
    final c = _ctrl;
    HapticFeedback.lightImpact();
    _wasPlaying = c?.value.isPlaying ?? false;
    _volumeAtStart = widget.volume;
    SystemVolume.instance.get().then((v) {
      if (!_volumeMode) _volumeAtStart = v;
    });
    if (c != null && _ready) {
      c.setPlaybackSpeed(2);
      if (!_wasPlaying) c.play();
    }
    setState(() {
      _fast = c != null && _ready;
      _volumeMode = false;
    });
  }

  void _holdMove(LongPressMoveUpdateDetails d) {
    final dy = d.offsetFromOrigin.dy;
    if (!_volumeMode) {
      if (dy.abs() < 18) return;
      // finger moved up/down -> volume mode (normal speed)
      _ctrl?.setPlaybackSpeed(1);
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
    final c = _ctrl;
    if (c != null && _ready) {
      c.setPlaybackSpeed(1);
      if (!_wasPlaying) c.pause();
    }
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
            // smooth bar: drag or tap to jump in the video
            SizedBox(
              height: 18,
              child: _ready && _ctrl != null
                  ? SmoothSeekBar(
                      key: ValueKey(_ctrl),
                      controller: _ctrl!,
                      startMs: _startMs,
                      endMs: _endMs,
                    )
                  : const Align(
                      alignment: Alignment.bottomCenter,
                      child: SizedBox(
                        height: 3,
                        width: double.infinity,
                        child: ColoredBox(color: Color(0xFF3A3D44)),
                      ),
                    ),
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
              child: _items.length == 1
                  ? _media(c, 0)
                  : PageView.builder(
                      key: const ValueKey('clip-items'),
                      controller: _itemPages,
                      itemCount: _items.length,
                      onPageChanged: _goToItem,
                      itemBuilder: (context, i) => _media(c, i),
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
                  if (!_ready && !_failed && !kDisableVideoPlayback)
                    const Center(child: CircularProgressIndicator()),
                  if (_items.length > 1) ...[
                    Positioned(
                      right: 12,
                      top: MediaQuery.of(context).padding.top + 14,
                      child: MediaPill(text: '${_item + 1}/${_items.length}'),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: MediaQuery.of(context).padding.top + 20,
                      child: PageDots(count: _items.length, index: _item),
                    ),
                  ],
                  if (_failed)
                    const Center(
                      child: Text(
                        "Couldn't load this clip",
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    ),
                  if (_ready &&
                      _ctrl != null &&
                      !_ctrl!.value.isPlaying &&
                      !_fast)
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
                    Positioned(
                      // top-right, no background (v0.7)
                      right: 14,
                      top: MediaQuery.of(context).padding.top + 64,
                      child: _VolumeHud(value: widget.volume),
                    ),
                  Center(child: _HeartBurst(animation: _heart)),
                ],
              ),
            ),
            // 3) buttons (top layer — no double-tap delay)
            // buttons sit ABOVE the username row
            Positioned(
              right: 6,
              bottom: 60,
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
                    _ctrl?.pause();
                    openProfile(context, c.authorId);
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Avatar(
                        url: c.authorPhotoUrl,
                        name: c.authorUsername,
                        size: 34,
                        uid: c.authorId,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
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
                            if (c.hasMusic) ...[
                              const SizedBox(height: 3),
                              MusicChip(name: c.audioName),
                            ],
                          ],
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

  /// One photo or video of this clip.
  Widget _media(Post c, int i) {
    final m = _items[i];
    if (!m.isVideo) return MediaPhoto(url: m.url);
    final screen = MediaQuery.of(context).size;
    final screenAspect =
        screen.width / (screen.height <= 0 ? 1 : screen.height);
    // fill the screen when the shape is close, else show it whole
    final close = (m.aspectRatio - screenAspect).abs() / screenAspect < 0.2;
    final fit = close ? BoxFit.cover : BoxFit.contain;
    final ctrl = _ctrl;
    if (i != _item || !_ready || ctrl == null) {
      return ColoredBox(
        color: Colors.black,
        child: m.thumbUrl.isEmpty
            ? (i == 0 ? ClipCoverBackground(post: c) : const SizedBox.expand())
            : SizedBox.expand(child: NetImage(m.thumbUrl, fit: fit)),
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: videoSurface(ctrl, m.edits.filter, fit: fit),
    );
  }

  Widget _actions(Post c, bool liked, bool likedServer) {
    // hidden counts are still shown to the owner
    final mine = c.authorId == ContentFilter.instance.uid;
    String count(int n, bool hidden, String word) =>
        hidden && !mine ? word : compactCount(n);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Action(
          icon: liked ? Icons.favorite : Icons.favorite_border,
          color: liked ? AppColors.like : Colors.white,
          label: count(
            _like.count(c.likesCount, likedServer),
            c.hideLikes,
            'Like',
          ),
          onTap: () => _toggle(_like, !liked, () => _repo.setLiked(c, !liked)),
        ),
        _Action(
          icon: Icons.chat_bubble_outline,
          label: count(c.commentsCount, c.hideComments, 'Comment'),
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
              label: count(
                _repost.count(c.repostsCount, server),
                c.hideReposts,
                'Repost',
              ),
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
          label: c.sharesCount == 0
              ? 'Share'
              : count(c.sharesCount, c.hideShares, 'Share'),
          onTap: () => sharePost(context, c),
        ),
        if (c.hasMusic)
          _Action(
            icon: widget.muted ? Icons.music_off : Icons.music_note,
            label: widget.muted ? 'Unmute' : 'Music',
            onTap: widget.onToggleMute,
          )
        else if (c.items.every((m) => !m.isVideo))
          const SizedBox.shrink()
        else if (_edits.muted)
          _Action(
            icon: Icons.music_off_outlined,
            label: 'No sound',
            onTap: () => ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                const SnackBar(
                  content: Text('This clip was posted without sound'),
                ),
              ),
          )
        else
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
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      spans.add(
        TextSpan(
          text: m.group(0),
          style: const TextStyle(
            color: AppColors.lime,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
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
                            const Icon(
                              Icons.keyboard_arrow_down,
                              size: 20,
                              color: AppColors.textSecondary,
                            ),
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
                        _detail(
                          Icons.schedule,
                          'Posted ${fullDate(post.createdAt)}',
                        ),
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

  Widget _detail(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Row(
      children: [
        Icon(icon, size: 15, color: AppColors.textSecondary),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
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
    const shadow = [Shadow(color: Colors.black54, blurRadius: 6)];
    return SizedBox(
      key: const ValueKey('volume-hud'),
      width: 48,
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
          Icon(icon, size: 20, shadows: shadow),
          const SizedBox(height: 2),
          Text(
            '${(value * 100).round()}%',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              shadows: shadow,
            ),
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
  Widget build(BuildContext context) {
    const bg = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1E1B3A), Colors.black],
        ),
      ),
    );
    if (post.thumbUrl.isEmpty) return bg;
    return Stack(
      fit: StackFit.expand,
      children: [
        bg,
        NetImage(post.thumbUrl, fit: BoxFit.cover),
      ],
    );
  }
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
