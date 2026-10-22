import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../../core/navigation/page_cover.dart';
import '../../../core/services/app_settings.dart';
import '../../../core/services/watch_clock.dart';
import '../../../core/services/content_filter.dart';
import '../../../core/services/hyper_feed.dart';
import '../../../core/services/hyper_intelligence.dart';
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
import '../../../shared/widgets/see_translation.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/media_links.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/follow_chip.dart';
import '../../../shared/widgets/hi_blur.dart';
import '../../../shared/widgets/media_view.dart';
import '../../../shared/widgets/net_image.dart';
import '../../../shared/widgets/seek_bar.dart';
import '../../../shared/widgets/video_extras.dart';
import '../../music/presentation/music_screen.dart';
import '../../post/data/post_repository.dart';
import '../data/clips_warmup.dart';
import '../../post/presentation/comments_sheet.dart';
import '../../post/presentation/create_sheet.dart';
import '../../post/presentation/my_post_picker.dart' show ReplyStickerChip;
import '../../post/presentation/post_menu.dart';
import '../../profile/data/user_repository.dart';
import '../../../core/services/video_cache.dart';
import '../../../shared/widgets/bounce.dart';
import '../../../shared/widgets/tagged_text.dart';
import '../../../shared/widgets/verified_badge.dart';

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
  bool _panelOpen = false; // comments open: no back button / title
  int _count = 0;
  final Set<String> _deleted = {};
  Stream<List<Post>>? _stream;
  bool _refreshing = false;

  // v0.19 Hyper Intelligence: ranked, steady order
  Stream<List<Post>> _makeStream() => PostRepository.instance
      .recent(type: Post.clip, limit: ClipsWarmup.limit)
      .map((l) => HyperFeed.instance.ordered('clips', l, mode: FeedMode.clips));

  /// v0.0.1: refresh button = new clips, fresh order, back to the top.
  Future<void> _refresh() async {
    if (_refreshing || widget.clips != null) return;
    HapticFeedback.selectionClick();
    HyperFeed.instance.reset('clips');
    setState(() {
      _refreshing = true;
      _order.clear();
      _current = 0;
      _prefetchedFor = -1;
      _showTopBar = true;
      _stream = _makeStream();
    });
    if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(0);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (mounted) setState(() => _refreshing = false);
  }

  @override
  void initState() {
    super.initState();
    if (widget.clips == null) _stream = _makeStream();
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

  /// Order of the clips you have seen so far. New clips from the server
  /// go to the END, so the clip you watch never changes under you (v0.8:
  /// a paused clip started again when a new clip arrived).
  final List<Post> _order = [];

  Widget _pager(List<Post> all) {
    final fresh = all
        .where(
          (c) => !_deleted.contains(c.id) && !HyperFeed.instance.isHidden(c.id),
        )
        .toList();
    final List<Post> clips;
    if (widget.clips != null) {
      clips = fresh;
    } else {
      final merged = stableMerge(_order, fresh, keepUpTo: _current);
      _order
        ..clear()
        ..addAll(merged);
      clips = merged;
    }
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
        // v0.18 Hyper Intelligence: a sensitive clip is blurred until
        // "Tap to view" (it does not play or make sound before)
        itemBuilder: (context, i) => HyperIntelligence.instance.blurs(clips[i])
            ? HiBlur(
                key: ValueKey('hi-clip-${clips[i].id}'),
                imageUrl: clips[i].coverUrl,
                onReveal: () =>
                    setState(() => HyperIntelligence.instance.reveal(clips[i])),
              )
            : ClipPlayer(
                key: ValueKey(clips[i].id),
                clip: clips[i],
                active: i == _current,
                muted: _muted,
                volume: _volume,
                autoScroll: autoScroll,
                onToggleMute: _toggleMute,
                onVolumeChanged: _setVolume,
                onFinished: _next,
                onPanel: (open) {
                  if (mounted) setState(() => _panelOpen = open);
                },
                onDeleted: () => setState(() => _deleted.add(clips[i].id)),
                source:
                    widget.source ??
                    (widget.clips == null
                        ? ViewSource.clips
                        : ViewSource.other),
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
              // the video goes down behind the name / caption and the
              // phone's nav bar (the caption bar keeps its own space)
              child: SafeArea(
                top: false,
                bottom: false,
                child: widget.clips != null
                    ? _pager(widget.clips!)
                    : StreamBuilder<List<Post>>(
                        stream: _stream,
                        initialData: ClipsWarmup.instance.latest,
                        builder: (context, snap) {
                          if (snap.hasError) {
                            return Center(child: ErrorView(error: snap.error));
                          }
                          if (!snap.hasData) {
                            return const LoadingView(kind: SkeletonKind.clip);
                          }
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
                ignoring: !_showTopBar || _panelOpen,
                child: AnimatedSlide(
                  offset: _showTopBar && !_panelOpen
                      ? Offset.zero
                      : const Offset(0, -1),
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  child: AnimatedOpacity(
                    opacity: _showTopBar && !_panelOpen ? 1 : 0,
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
                            const Spacer(),
                            // v0.0.1: refresh (hides with the back button)
                            if (widget.clips == null)
                              IconButton(
                                key: const ValueKey('clips-refresh'),
                                tooltip: 'Refresh',
                                onPressed: _refresh,
                                icon: _refreshing
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.refresh_rounded,
                                        size: 25,
                                        shadows: [
                                          Shadow(
                                            blurRadius: 8,
                                            color: Colors.black54,
                                          ),
                                        ],
                                      ),
                              ),
                            const SizedBox(width: 4),
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

/// Keeps the order of [old]: known clips keep their place (with fresh
/// data), new clips are added at the end. Clips gone from the server are
/// dropped, except up to index [keepUpTo] (so the page you watch stays).
@visibleForTesting
List<Post> stableMerge(List<Post> old, List<Post> fresh, {int keepUpTo = 0}) {
  if (old.isEmpty) return fresh;
  final byId = {for (final p in fresh) p.id: p};
  final out = <Post>[];
  for (var i = 0; i < old.length; i++) {
    final now = byId.remove(old[i].id);
    if (now != null) {
      out.add(now);
    } else if (i <= keepUpTo) {
      out.add(old[i]);
    }
  }
  for (final p in fresh) {
    if (byId.containsKey(p.id)) out.add(p);
  }
  return out;
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
    this.onPanel,
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

  /// Comments opened (true) / closed (false).
  final ValueChanged<bool>? onPanel;
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
    with SingleTickerProviderStateMixin, PageCoverAware {
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

  /// v0.11: tries after an error (direct from the internet, small copy).
  int _tries = 0;
  bool _recovering = false;
  bool _finishedSent = false;
  bool _detailsOpen = false;
  Timer? _photoTimer;

  // adaptive quality (small copy while the network is slow)
  bool _usingLow = false;

  /// You paused it: nothing starts it again by itself (v0.8 fix).
  bool _userPaused = false;

  /// Comments opened full screen: paused until they go down (v0.9).
  bool _coverPaused = false;
  bool get _mustStayPaused => _userPaused || _coverPaused || pageCovered;

  /// A page opened on top (profile, camera for a reply…): pause, and play
  /// again when it closes (v0.9).
  @override
  void onPageCoverChanged(bool covered) {
    final music = widget.clip.hasMusic;
    if (covered) {
      _ctrl?.pause();
      if (music) MusicPlayer.instance.pause(_musicOwner);
    } else if (widget.active && !_userPaused && !_coverPaused) {
      if (_isVideo && _ready) _play();
      if (music) MusicPlayer.instance.resume(_musicOwner);
    }
    if (mounted) setState(() {});
  }

  /// Top of the comments panel (null = closed). The video plays small
  /// above it (v0.9).
  final ValueNotifier<double?> _panelTop = ValueNotifier<double?>(null);
  String _openUrl = ''; // what the player plays (for the pool)
  StallWatch? _stall;
  Timer? _startTimer;

  // watch time of the current video (for the author's Analytics)
  int _maxWatch = 0;
  bool _completed = false;
  int _lastTickPos = 0;

  // v0.0.1: the view counts after 3 s of real watching (once)
  final WatchClock _viewClock = WatchClock();
  Timer? _viewTimer;
  bool _viewSent = false;

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
  final _skipper = CutSkipper();
  VoiceTrack? _voice;
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
    _tries = 0;
    _finishedSent = false;
    _photoTimer?.cancel();
    if (!_isVideo) {
      _ready = true;
      return;
    }
    if (kDisableVideoPlayback) return;
    // v0.14 (like Reels): the copy that can start at once; a player that
    // is already prepared (either copy) wins
    final mix = widget.clip.hasMusic;
    final pick = NetQuality.urlFor(_cur);
    final other = pick == _cur.url ? _cur.lowUrl : _cur.url;
    final url =
        !VideoPool.instance.has(pick, mixWithOthers: mix) &&
            other.isNotEmpty &&
            VideoPool.instance.has(other, mixWithOthers: mix)
        ? other
        : pick;
    _usingLow = _cur.lowUrl.isNotEmpty && url == _cur.lowUrl;
    _openUrl = url;
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
          _attachVoice(c);
          if (widget.active && !_mustStayPaused) _play();
        })
        .catchError((Object e) {
          if (!mounted || _ctrl != c) return;
          debugPrint('clip open: $e');
          _recover(c);
        });
  }

  /// v0.11: the video could not open ("Couldn't load this clip" before).
  /// Usual reasons: too many video players at once (the phone has only a
  /// few video decoders) or a broken saved copy. So: free the waiting
  /// players, delete the saved copy, try straight from the internet, then
  /// the small copy, and only then show "Tap to retry".
  Future<void> _recover(VideoPlayerController failed) async {
    if (_recovering) return;
    _recovering = true;
    final item = _item;
    final url = _openUrl;
    try {
      failed.removeListener(_onTick);
      _stall?.dispose();
      _stall = null;
      _startTimer?.cancel();
      if (_ctrl == failed) _ctrl = null;
      failed.dispose();
      _tries++;
      VideoPool.instance.clear(); // frees the phone's video decoders
      await VideoCache.instance.forget(url);
      if (!mounted || _item != item || _ctrl != null) return;
      final low = _cur.lowUrl;
      String? next;
      if (_tries == 1) {
        next = url; // same video, straight from the internet
      } else if (_tries == 2 && low.isNotEmpty && url != low) {
        next = low;
        _usingLow = true;
      }
      if (next == null) {
        setState(() {
          _ready = false;
          _failed = true;
        });
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted || _item != item || _ctrl != null) return;
      final c = VideoCache.instance.direct(
        next,
        mixWithOthers: widget.clip.hasMusic,
      );
      _ctrl = c;
      _openUrl = next;
      c.setLooping(!_manualLoop);
      c.addListener(_onTick);
      try {
        await c.initialize().timeout(const Duration(seconds: 20));
      } catch (e) {
        debugPrint('clip retry $_tries: $e');
        if (mounted && _ctrl == c) {
          _recovering = false;
          await _recover(c);
        }
        return;
      }
      if (!mounted || _ctrl != c) return;
      _applyTrim(c);
      if (_startMs > 0) await c.seekTo(Duration(milliseconds: _startMs));
      if (!mounted || _ctrl != c) return;
      setState(() {
        _ready = true;
        _failed = false;
      });
      c.setVolume(_effectiveVolume);
      _attachVoice(c);
      if (widget.active && !_mustStayPaused) _play();
    } finally {
      _recovering = false;
    }
  }

  /// "Tap to retry".
  void _retry() {
    final old = _ctrl;
    _ctrl = null;
    old?.removeListener(_onTick);
    old?.dispose();
    setState(_openItem);
  }

  // v0.8: through the disk cache (watching again = no new download)
  VideoPlayerController _newCtrl(String url) =>
      VideoCache.instance.controller(url, mixWithOthers: widget.clip.hasMusic);

  void _applyTrim(VideoPlayerController c) {
    final total = c.value.duration.inMilliseconds;
    _startMs = VideoTime.firstPlayable(
      _edits.trimStartMs,
      _edits.cuts,
    ).clamp(0, total);
    // v0.12: a removed part at the end ends the video earlier
    final rawEnd = _edits.trimEndMs > _startMs
        ? _edits.trimEndMs.clamp(0, total)
        : total;
    final end = VideoTime.playableEnd(rawEnd, _edits.cuts);
    _endMs = end < total && end > _startMs ? end : 0;
  }

  /// v0.12: voice over of this item follows the player.
  void _attachVoice(VideoPlayerController c) {
    final e = _edits;
    if (!e.hasVoice) {
      _voice?.dispose();
      _voice = null;
      return;
    }
    if (_voice == null || !identical(_voice!.edits, e)) {
      _voice?.dispose();
      _voice = VoiceTrack(e);
    }
    _voice!.muted = widget.muted;
    _voice!.attach(c);
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
    _openUrl = low;
    old.removeListener(_onTick);
    c.addListener(_onTick);
    _attachVoice(c);
    setState(() {
      _ctrl = c;
      _ready = true;
      _failed = false;
    });
    if (widget.active && playing && !_mustStayPaused) {
      _play();
      if (_fast) c.setPlaybackSpeed(2);
    }
    old.dispose();
  }

  /// Frees the current video player (and reports watch time).
  void _closeItem() {
    _photoTimer?.cancel();
    _viewTimer?.cancel();
    _viewClock.pause(DateTime.now().millisecondsSinceEpoch);
    _startTimer?.cancel();
    _stall?.dispose();
    _stall = null;
    final c = _ctrl;
    _ctrl = null;
    _voice?.detach();
    if (c != null) {
      c.removeListener(_onTick);
      if (_ready && !_failed) {
        // v0.8: keep it ready, swiping back starts at once
        VideoPool.instance.keep(
          _openUrl,
          c,
          mixWithOthers: widget.clip.hasMusic,
        );
      } else {
        c.dispose();
      }
    }
    _sendWatch();
  }

  void _sendWatch() {
    if (_maxWatch > 0 || _completed) {
      _repo.reportWatch(widget.clip, watchMs: _maxWatch, completed: _completed);
    }
    _maxWatch = 0;
    _completed = false;
    _lastTickPos = 0;
  }

  void _goToItem(int i) {
    if (i == _item || i < 0 || i >= _items.length) return;
    _userPaused = false;
    setState(() {
      _closeItem();
      _item = i;
      _openItem();
    });
    if (widget.active && !_isVideo) _startPhotoTimer();
    _photoViewTimer();
  }

  /// v0.0.1: photo items count after 3 s on screen (videos: [WatchClock]).
  void _photoViewTimer() {
    _viewTimer?.cancel();
    if (_viewSent || !widget.active || _isVideo) return;
    _viewTimer = Timer(const Duration(milliseconds: WatchClock.viewAfterMs), () {
      if (mounted && widget.active) _sendView();
    });
  }

  void _sendView() {
    if (_viewSent) return;
    _viewSent = true;
    _viewTimer?.cancel();
    _repo.addView(widget.clip, source: widget.source);
  }

  /// Clip came on screen.
  void _startActive() {
    _userPaused = false; // came back to it: plays again
    // v0.0.1: seen at once (smart feed); the view counts after 3 s
    _repo.markSeen(widget.clip);
    _photoViewTimer();
    if (widget.clip.hasMusic && !_coverPaused && !pageCovered) {
      MusicPlayer.instance.play(
        _musicOwner,
        widget.clip.audioUrl,
        volume: widget.muted ? 0 : 1,
        startMs: widget.clip.audioStartMs,
      );
    }
    if (_isVideo) {
      if (_ready && !_coverPaused && !pageCovered) _play();
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
    if (v.hasError && v.isInitialized && !_recovering && !_failed) {
      // v0.11: broke while playing (e.g. decoder taken by another app)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _ctrl == c) _recover(c);
      });
      return;
    }
    if (!v.isInitialized || v.duration <= Duration.zero) return;
    final pos = v.position.inMilliseconds;
    final watched = pos - _startMs;
    if (watched > _maxWatch) _maxWatch = watched;
    // v0.20: watched to the end - also when the video loops by itself
    // (before, looping clips never counted as "watched to the end").
    // The position comes only about every 0.5 s.
    if (!_completed &&
        VideoTime.reachedEnd(
          pos: pos,
          lastPos: _lastTickPos,
          startMs: _startMs,
          endMs: _endOrTotal,
        )) {
      _completed = true;
    }
    _lastTickPos = pos;
    if (!_viewSent &&
        widget.active &&
        _viewClock.update(
          playing: v.isPlaying && !v.isBuffering,
          nowMs: DateTime.now().millisecondsSinceEpoch,
          completed: _completed,
        )) {
      _sendView();
    }
    if (_mustStayPaused) {
      // v0.9: whatever started it (system, buffering, loop) -> stop again.
      // Holding (2x) may play it for a moment.
      if (v.isPlaying && !_fast) c.pause();
      return;
    }
    if (!_manualLoop || !widget.active || _finishedSent) return;
    final atEnd =
        pos >= _endOrTotal - 120 ||
        (!v.isPlaying && pos >= v.duration.inMilliseconds - 250);
    if (!atEnd) {
      // v0.12: jump over removed parts
      _skipper.check(c, _edits, startMs: _startMs, endMs: _endMs);
      return;
    }
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
        _viewTimer?.cancel();
        _viewClock.pause(DateTime.now().millisecondsSinceEpoch);
        c?.pause();
        c?.setPlaybackSpeed(1);
        _sendWatch();
        if (widget.clip.hasMusic) MusicPlayer.instance.stop(_musicOwner);
      }
    }
    if (widget.muted != old.muted) {
      c?.setVolume(_effectiveVolume);
      _voice?.muted = widget.muted;
      if (widget.clip.hasMusic && widget.active) {
        MusicPlayer.instance.setVolume(widget.muted ? 0 : 1);
      }
    }
  }

  @override
  void dispose() {
    _closeItem();
    _voice?.dispose();
    if (widget.clip.hasMusic) MusicPlayer.instance.stop(_musicOwner);
    _itemPages.dispose();
    _heart.dispose();
    _panelTop.dispose();
    super.dispose();
  }

  // ---------------- gestures ----------------

  void _togglePlay() {
    final c = _ctrl;
    if (!_ready || c == null) return;
    final music = widget.clip.hasMusic;
    setState(() {
      // v0.10: follow what the USER did last, not isPlaying (a tap used to
      // pause in the long-press-cancel code first and then play here).
      if (!_userPaused) {
        _userPaused = true;
        c.pause();
        if (music) MusicPlayer.instance.pause(_musicOwner);
      } else {
        _userPaused = false;
        _play();
        if (music) MusicPlayer.instance.resume(_musicOwner);
      }
    });
  }

  // ---------------- comments panel (v0.9) ----------------

  Future<void> _openComments(Post c) async {
    setState(() => _detailsOpen = false);
    widget.onPanel?.call(true);
    try {
      await showComments(context, c, onSheetTop: _onSheetTop);
    } finally {
      // v0.10: the panel says null itself when its close animation ends
      // (buttons come back). Here only the back button / title.
      widget.onPanel?.call(false);
    }
  }

  void _onSheetTop(double? top) {
    if (!mounted) return;
    _panelTop.value = top;
    final full = top != null && top < 24;
    if (full == _coverPaused) return;
    _coverPaused = full;
    final music = widget.clip.hasMusic;
    if (full) {
      _ctrl?.pause();
      if (music) MusicPlayer.instance.pause(_musicOwner);
    } else if (widget.active && !_userPaused && !pageCovered) {
      if (_isVideo && _ready) _play();
      if (music) MusicPlayer.instance.resume(_musicOwner);
    }
    setState(() {});
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
    // only called by ClipTapArea after a real hold started
    if (c != null && _ready) {
      c.setPlaybackSpeed(1);
      if (!_wasPlaying || _mustStayPaused) c.pause();
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
        return LayoutBuilder(
          builder: (context, box) => ValueListenableBuilder<double?>(
            valueListenable: _panelTop,
            builder: (context, top, _) => _layout(c, top, box.maxHeight),
          ),
        );
      },
    );
  }

  /// 0 = comments open (video small above the panel, no buttons),
  /// 1 = normal. Follows the panel while it slides.
  double _big = 1;

  Widget _layout(Post c, double? top, double h) {
    final pad = MediaQuery.paddingOf(context).top;
    final p = ClipLayout.bigness(top, h);
    _big = p;
    final t = top ?? h;
    final below = (1 - p) * math.max(0.0, h - math.max(t, pad));
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final small = p < 1;
    // v0.11: same widget tree small or full (a changing key here rebuilt
    // everything and made the video jump when the comments closed).
    // Fix update: the video fills down to the bottom (behind the caption
    // bar); buttons + caption are a layer on top.
    return StreamBuilder<bool>(
      stream: _likedStream,
      builder: (context, likeSnap) {
        final likedServer = likeSnap.data ?? false;
        final liked = _like.show(likedServer);
        return ColoredBox(
          color: Colors.black,
          child: Stack(
            children: [
              Positioned(
                key: const ValueKey('clip-video-layer'),
                left: 0,
                right: 0,
                top: pad * (1 - p),
                bottom: below,
                child: _videoArea(c, liked, small: small),
              ),
              Positioned.fill(
                child: Column(
                  children: [
                    SizedBox(
                      key: ValueKey(small ? 'clip-small' : 'clip-full'),
                      height: pad * (1 - p),
                    ),
                    Expanded(child: _overlayLayer(c, liked, likedServer, small)),
                    ClipRect(
                      child: Align(
                        alignment: Alignment.topCenter,
                        heightFactor: p,
                        child: IgnorePointer(
                          ignoring: small,
                          child: Opacity(
                            opacity: p,
                            child: ColoredBox(
                              key: const ValueKey('clip-bars'),
                              color: const Color(0x99000000),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _bottomBars(c),
                                  SizedBox(height: safeBottom),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: below),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _bottomBars(Post c) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
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
  }

  /// The video / photos + their gestures (bottom layer).
  Widget _videoArea(Post c, bool liked, {bool small = false}) {
    return Stack(
          fit: StackFit.expand,
          children: [
            // 1) the video + its gestures (bottom layer)
            ClipTapArea(
              onTap: _togglePlay,
              onDoubleTap: () => _doubleTapLike(c, liked),
              onHoldStart: _holdStart,
              onHoldMove: _holdMove,
              onHoldEnd: _holdEnd,
              child: _items.length == 1
                  ? _media(c, 0, small: small)
                  : PageView.builder(
                      key: const ValueKey('clip-items'),
                      controller: _itemPages,
                      itemCount: _items.length,
                      onPageChanged: _goToItem,
                      itemBuilder: (context, i) => _media(c, i, small: small),
                    ),
            ),
            if (small)
              IgnorePointer(
                child: Opacity(
                  opacity: 1 - _big,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (!_ready && !_failed && !kDisableVideoPlayback)
                        const LoadingSweep(),
                      if (_ready &&
                          _ctrl != null &&
                          !_ctrl!.value.isPlaying &&
                          !_coverPaused)
                        Center(
                          child: Icon(
                            Icons.play_arrow_rounded,
                            size: 56,
                            color: Colors.white.withValues(alpha: 0.8),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
  }

  /// Buttons, name, dots (above the video, under nothing). Empty parts let
  /// touches through to the video. They fade out / in with the panel.
  Widget _overlayLayer(Post c, bool liked, bool likedServer, bool small) {
    if (_big <= 0) return const SizedBox.expand();
    return IgnorePointer(
      ignoring: small,
      child: Opacity(
        opacity: _big,
        child: Stack(
          fit: StackFit.expand,
          children: _overlays(c, liked, likedServer),
        ),
      ),
    );
  }

  /// Gradients, indicators, buttons and the author row (full size only).
  List<Widget> _overlays(Post c, bool liked, bool likedServer) {
    return [
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
              const LoadingSweep(),

            if (_ready && _ctrl != null && !_ctrl!.value.isPlaying && !_fast)
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
      // v0.11: failed after all tries: tap to try again
      if (_failed)
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Couldn't load this clip",
                style: TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const ValueKey('clip-retry'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white24,
                  foregroundColor: Colors.white,
                ),
                onPressed: _retry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Tap to retry'),
              ),
            ],
          ),
        ),
      // 3) buttons (top layer — no double-tap delay)
      // buttons sit ABOVE the username row
      Positioned(right: 6, bottom: 60, child: _actions(c, liked, likedServer)),
      // v0.9: "Reply to @name's comment" sticker
      if (c.replyTo != null)
        Positioned(
          left: 14,
          bottom: (c.showsAudio ? 74 : 60) + (_items.length > 1 ? 16 : 0),
          right: 80,
          child: Align(
            alignment: Alignment.centerLeft,
            child: ReplyStickerChip(
              reply: c.replyTo!,
              onTap: () => openPostById(context, c.replyTo!.postId),
            ),
          ),
        ),
      // fix update: dots above the name (photos / videos of this clip)
      if (_items.length > 1)
        Positioned(
          left: 0,
          right: 0,
          bottom: c.showsAudio ? 66 : 56,
          child: IgnorePointer(
            child: PageDots(
              key: const ValueKey('clip-dots'),
              count: _items.length,
              index: _item,
            ),
          ),
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
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
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
                          VerifiedBadge(uid: c.authorId, size: 14),
                        ],
                      ),
                      if (c.showsAudio) ...[
                        const SizedBox(height: 3),
                        MusicChip(
                          key: ValueKey('clip-audio-${c.id}'),
                          name: c.audioLabel,
                          // never falls through to "open profile"
                          onTap: () {
                            if (!c.hasAudioPage) return;
                            _ctrl?.pause();
                            openMusicOf(context, c);
                          },
                        ),
                      ],
                    ],
                  ),
                ),
                // v0.12: Follow button next to the name
                FollowChip(targetUid: c.authorId),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  /// One photo or video of this clip.
  Widget _media(Post c, int i, {bool small = false}) {
    final m = _items[i];
    // v0.0.2: link stickers on top (tap = open)
    if (!m.isVideo) return withMediaLinks(MediaPhoto(url: m.url), m);
    final screen = MediaQuery.of(context).size;
    final screenAspect =
        screen.width / (screen.height <= 0 ? 1 : screen.height);
    // fill the screen when the shape is close (9:16 on tall phones too),
    // else show it whole
    final close = ClipLayout.fillsScreen(m.aspectRatio, screenAspect);
    final ctrl = _ctrl;
    final live = i == _item && _ready ? ctrl : null;
    if (live == null && m.thumbUrl.isEmpty) {
      return ColoredBox(
        color: Colors.black,
        child: i == 0 ? ClipCoverBackground(post: c) : const SizedBox.expand(),
      );
    }
    // v0.11: "fill the screen" grows smoothly (contain -> cover) while
    // the comments panel closes, instead of jumping at the end
    final grow = close ? _big : 0.0;
    final aspect = live != null
        ? safeAspect(live.value.aspectRatio)
        : m.aspectRatio;
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, box) {
          Widget child = live != null
              ? videoSurface(
                  live,
                  m.edits.filter,
                  overlays: m.edits.overlays,
                  face: m.edits.face,
                )
              : SizedBox.expand(
                  child: NetImage(m.thumbUrl, fit: BoxFit.contain),
                );
          // v0.0.2: links grow with the video (stay on their spot)
          child = withMediaLinks(child, m, aspect: aspect);
          final k = ClipLayout.coverScale(box.maxWidth, box.maxHeight, aspect);
          final scale = 1 + (k - 1) * grow;
          if (scale > 1.001) {
            child = ClipRect(
              child: Transform.scale(scale: scale, child: child),
            );
          }
          return child;
        },
      ),
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
          onTap: () => _openComments(c),
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
          // see-through: the video shows behind (the bar box is dark)
          color: Colors.transparent,
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
                          // v0.19: + See translation
                          SeeTranslation(
                            text: post.caption,
                            light: true,
                            builder: (text, translated) => TaggedText(
                              text,
                              key: ValueKey(
                                translated
                                    ? 'clip-caption-translated'
                                    : 'clip-caption-open',
                              ),
                              style: const TextStyle(
                                fontSize: 14.5,
                                height: 1.4,
                              ),
                            ),
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
                          ? TaggedText(
                              post.caption,
                              key: const ValueKey('clip-caption'),
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
  final _bounce = GlobalKey<BounceState>();

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
      onTap: () {
        _bounce.currentState?.play(); // v0.8: springy pop
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _down ? 0.82 : 1,
        duration: const Duration(milliseconds: 90),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: SizedBox(
            width: 52,
            child: Column(
              children: [
                Bounce(
                  key: _bounce,
                  // liked / saved / reposted -> the icon pops
                  trigger: widget.icon,
                  child: Icon(
                    widget.icon,
                    size: 25,
                    color: widget.color,
                    shadows: const [
                      Shadow(blurRadius: 8, color: Colors.black54),
                    ],
                  ),
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

/// Tap / double tap / hold area of a clip (v0.10).
///
/// Flutter calls onLongPressCancel on EVERY normal tap. Before, that ran
/// the "end of 2x hold" code, which paused the video, and then the tap
/// (300 ms later) saw a paused video and played it again: "the clip plays
/// by itself after I pause it". Here [onHoldEnd] only comes after a real
/// [onHoldStart].
class ClipTapArea extends StatefulWidget {
  const ClipTapArea({
    super.key,
    required this.child,
    this.onTap,
    this.onDoubleTap,
    this.onHoldStart,
    this.onHoldMove,
    this.onHoldEnd,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final GestureLongPressStartCallback? onHoldStart;
  final GestureLongPressMoveUpdateCallback? onHoldMove;
  final VoidCallback? onHoldEnd;

  @override
  State<ClipTapArea> createState() => _ClipTapAreaState();
}

class _ClipTapAreaState extends State<ClipTapArea> {
  bool _holding = false;

  void _end() {
    if (!_holding) return; // a tap, not a hold
    _holding = false;
    widget.onHoldEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onDoubleTap: widget.onDoubleTap,
      onLongPressStart: (d) {
        _holding = true;
        widget.onHoldStart?.call(d);
      },
      onLongPressMoveUpdate: (d) {
        if (_holding) widget.onHoldMove?.call(d);
      },
      onLongPressEnd: (_) => _end(),
      onLongPressCancel: _end,
      child: widget.child,
    );
  }
}

/// v0.11: maths for the clip while the comments are open.
abstract final class ClipLayout {
  /// v0.11: ONE layout for both sizes. Before, open / closed were two
  /// different layouts and closing the comments jumped ("shock"); now the
  /// video grows back smoothly with the panel and the buttons fade in.
  static double bigness(double? top, double h) {
    if (top == null || h <= 0) return 1;
    return ((top - 0.4 * h) / (0.6 * h)).clamp(0.0, 1.0);
  }

  /// Fill the screen (crop a little) instead of black bars: tall videos
  /// close to the phone's shape. 9:16 on a 20:9 phone is 25% off -> fill.
  static bool fillsScreen(double videoAspect, double screenAspect) {
    if (videoAspect <= 0 || screenAspect <= 0) return false;
    if (videoAspect >= 1) return false; // square / wide: show it whole
    return (videoAspect - screenAspect).abs() / screenAspect < 0.35;
  }

  /// How much a "contain" picture must grow to "cover" a w x h box.
  static double coverScale(double w, double h, double aspect) {
    if (w <= 0 || h <= 0 || aspect <= 0 || !w.isFinite || !h.isFinite) {
      return 1;
    }
    final box = w / h;
    return box > aspect ? box / aspect : aspect / box;
  }
}
