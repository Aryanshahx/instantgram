import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../core/navigation/page_cover.dart';
import '../../core/services/media_prefetch.dart';
import '../../core/services/app_settings.dart';
import '../../core/services/music_player.dart';
import '../../core/services/net_quality.dart';
import '../../core/theme/app_colors.dart';
import '../../features/editor/filters.dart';
import '../models/post.dart';
import 'net_image.dart';
import '../../core/services/video_cache.dart';

/// Tests: don't create real video players.
bool kDisableVideoPlayback = false;

/// Tallest card shape in Discover (9:16) and widest (1.91:1).
const double kMinCardAspect = 9 / 16;
const double kMaxCardAspect = 1.91;

/// Card shape for a post: the first item's real shape (within limits).
double cardAspectFor(Post p) {
  final items = p.items;
  final a = items.isEmpty ? 1.0 : items.first.aspectRatio;
  return safeAspect(a).clamp(kMinCardAspect, kMaxCardAspect);
}

/// Draws a ready video safely: never crashes on a 0x0 size and only adds a
/// color filter when the video really has one.
Widget videoSurface(
  VideoPlayerController c,
  List<double>? filter, {
  BoxFit fit = BoxFit.contain,
}) {
  final v = c.value;
  final s = v.size;
  final w = s.width.isFinite && s.width > 0 ? s.width : 1080.0;
  final h = s.height.isFinite && s.height > 0
      ? s.height
      : w / safeAspect(v.aspectRatio);
  Widget video = VideoPlayer(c);
  if (filter != null &&
      filter.length == 20 &&
      !ColorMatrix.isIdentity(filter)) {
    video = ColorFiltered(
      colorFilter: ColorFilter.matrix(filter),
      child: video,
    );
  }
  return ClipRect(
    child: FittedBox(
      fit: fit,
      child: SizedBox(width: w, height: h, child: video),
    ),
  );
}

/// One photo, shown whole (no crop) on black.
class MediaPhoto extends StatelessWidget {
  const MediaPhoto({super.key, required this.url, this.fit = BoxFit.contain});
  final String url;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: SizedBox.expand(child: NetImage(url, fit: fit)),
    );
  }
}

/// A video item that plays only while [active].
/// Keeps its cover image until the first frame is ready.
class MediaVideo extends StatefulWidget {
  const MediaVideo({
    super.key,
    required this.item,
    required this.active,
    this.muted = false,
    this.mixWithOthers = false,
    this.fit = BoxFit.contain,
    this.onWatched,
  });

  final MediaItem item;
  final bool active;

  /// App-level mute (Discover sound button / music playing).
  final bool muted;

  /// true when the post has music (both must play together).
  final bool mixWithOthers;
  final BoxFit fit;

  /// Called when it stops playing: watched ms + reached the end.
  final void Function(int watchMs, bool completed)? onWatched;

  @override
  State<MediaVideo> createState() => _MediaVideoState();
}

class _MediaVideoState extends State<MediaVideo> {
  VideoPlayerController? _c;
  bool _ready = false;
  bool _failed = false;
  int _startMs = 0;
  int _endMs = 0;
  int _maxPos = 0;
  bool _completed = false;

  // adaptive quality (small copy while the network is slow)
  bool _usingLow = false;
  String _openUrl = ''; // what the player plays (for the pool)
  StallWatch? _stall;
  Timer? _startTimer;

  VideoEdits get _edits => widget.item.edits;

  double get _volume => (widget.muted || _edits.muted) ? 0 : 1;

  @override
  void initState() {
    super.initState();
    if (widget.active) _init();
  }

  @override
  void didUpdateWidget(covariant MediaVideo old) {
    super.didUpdateWidget(old);
    if (old.item.url != widget.item.url) {
      _release();
      if (widget.active) _init();
      return;
    }
    if (widget.active != old.active) {
      if (widget.active) {
        if (_c == null) {
          _init();
        } else if (_ready) {
          _c!.play();
        }
      } else {
        _release(); // frees the video decoder while off screen
      }
    }
    if (widget.muted != old.muted) _c?.setVolume(_volume);
  }

  // v0.8: through the disk cache (watching again = no new download)
  VideoPlayerController _newCtrl(String url) =>
      VideoCache.instance.controller(url, mixWithOthers: widget.mixWithOthers);

  void _applyTrim(VideoPlayerController c) {
    final total = c.value.duration.inMilliseconds;
    _startMs = _edits.trimStartMs.clamp(0, total);
    _endMs = _edits.trimEndMs > _startMs ? _edits.trimEndMs.clamp(0, total) : 0;
  }

  Future<void> _init() async {
    if (kDisableVideoPlayback || _c != null) return;
    final item = widget.item;
    // full quality, unless videos were buffering a moment ago
    _usingLow = NetQuality.slow && item.lowUrl.isNotEmpty;
    final url = _usingLow ? item.lowUrl : item.url;
    _openUrl = url;
    // ready player from the prefetch pool = instant start
    final pooled = VideoPool.instance.take(
      url,
      mixWithOthers: widget.mixWithOthers,
    );
    final c = pooled?.controller ?? _newCtrl(url);
    _c = c;
    _failed = false;
    if (!_usingLow && item.lowUrl.isNotEmpty) {
      _stall = StallWatch(c, onStall: _switchToLow);
      _startTimer = Timer(NetQuality.startTimeout, () {
        if (mounted && _c == c && !_ready) _switchToLow();
      });
    }
    try {
      await (pooled?.ready ?? c.initialize());
      if (!mounted || _c != c) {
        if (_c != c) return; // replaced by the small copy
        c.dispose();
        return;
      }
      _applyTrim(c);
      await c.setLooping(!_edits.hasTrim);
      if (_startMs > 0) await c.seekTo(Duration(milliseconds: _startMs));
      await c.setVolume(_volume);
      c.addListener(_tick);
      if (!mounted || _c != c) return;
      setState(() => _ready = true);
      if (widget.active) c.play();
    } catch (_) {
      if (!mounted || _c != c) return;
      if (!_usingLow && widget.item.lowUrl.isNotEmpty) {
        _switchToLow();
      } else {
        setState(() => _failed = true);
      }
    }
  }

  /// Buffering: continue with the smaller copy at the same moment.
  Future<void> _switchToLow() async {
    final old = _c;
    final low = widget.item.lowUrl;
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
    if (!mounted || _c != old) {
      c.dispose();
      return;
    }
    final wasReady = _ready;
    final pos = wasReady ? old.value.position : Duration.zero;
    _applyTrim(c);
    await c.setLooping(!_edits.hasTrim);
    final at = pos.inMilliseconds > _startMs
        ? pos
        : Duration(milliseconds: _startMs);
    if (at > Duration.zero) await c.seekTo(at);
    await c.setVolume(_volume);
    if (!mounted || _c != old) {
      c.dispose();
      return;
    }
    old.removeListener(_tick);
    c.addListener(_tick);
    _openUrl = low;
    setState(() {
      _c = c;
      _ready = true;
      _failed = false;
    });
    if (widget.active) c.play();
    old.dispose();
  }

  void _tick() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    final pos = c.value.position.inMilliseconds;
    final end = _endMs > 0 ? _endMs : c.value.duration.inMilliseconds;
    final watched = pos - _startMs;
    if (watched > _maxPos) _maxPos = watched;
    if (end > 0 && pos >= end - 150) {
      _completed = true;
      if (_edits.hasTrim) c.seekTo(Duration(milliseconds: _startMs));
    }
  }

  void _release() {
    _startTimer?.cancel();
    _stall?.dispose();
    _stall = null;
    final c = _c;
    if (c == null) return;
    final wasReady = _ready;
    _c = null;
    _ready = false;
    c.removeListener(_tick);
    if (wasReady) {
      // v0.8: keep it ready, scrolling back starts at once
      VideoPool.instance.keep(
        _openUrl,
        c,
        mixWithOthers: widget.mixWithOthers,
      );
    } else {
      c.dispose();
    }
    if (_maxPos > 0 || _completed) {
      widget.onWatched?.call(_maxPos, _completed);
      _maxPos = 0;
      _completed = false;
    }
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final cover = widget.item.thumbUrl;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!_ready || c == null)
            cover.isEmpty
                ? const SizedBox.shrink()
                : NetImage(cover, fit: widget.fit),
          if (_ready && c != null)
            videoSurface(c, _edits.filter, fit: widget.fit),
          if (_failed)
            const Center(
              child: Text(
                "Couldn't play this video",
                style: TextStyle(color: AppColors.textSecondary),
              ),
            )
          else if (!_ready && widget.active && !kDisableVideoPlayback)
            const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
          if (!widget.active)
            Center(
              child: Icon(
                Icons.play_circle_fill,
                size: 56,
                color: Colors.white.withValues(alpha: 0.8),
              ),
            ),
        ],
      ),
    );
  }
}

/// All photos / videos of a post for Discover and the post page:
///  * real shape of the first item, others fit inside (no crop)
///  * swipe left / right, i/N counter and dots
///  * videos and music start when 60% of the card is on screen
///    (or it covers half the screen)
class PostMedia extends StatefulWidget {
  const PostMedia({
    super.key,
    required this.post,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.onSeen,
    this.onWatched,
    this.overlay,
  });

  final Post post;

  /// Tap (when null: tap mutes / unmutes if there is sound).
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;

  /// Hold (your own posts: Analytics / Pin).
  final VoidCallback? onLongPress;

  /// Called once after the post was on screen for 1 second.
  final VoidCallback? onSeen;
  final void Function(int watchMs, bool completed)? onWatched;

  /// Extra layer on top (heart animation).
  final Widget? overlay;

  @override
  State<PostMedia> createState() => _PostMediaState();
}

class _PostMediaState extends State<PostMedia> with PageCoverAware {
  final PageController _pages = PageController();
  int _index = 0;
  bool _visible = false; // on screen AND no page (moments…) on top
  bool _onScreen = false;
  Timer? _seenTimer;
  bool _seenSent = false;

  Post get p => widget.post;
  String get _musicOwner => 'post-${p.id}';
  bool get _hasSound =>
      p.hasMusic || p.items.any((m) => m.isVideo && !m.edits.muted);

  @override
  void initState() {
    super.initState();
    AppSettings.instance.feedMuted.addListener(_onMute);
  }

  @override
  void dispose() {
    AppSettings.instance.feedMuted.removeListener(_onMute);
    _seenTimer?.cancel();
    if (p.hasMusic) MusicPlayer.instance.stop(_musicOwner);
    _pages.dispose();
    super.dispose();
  }

  void _onMute() {
    if (!mounted) return;
    setState(() {});
    if (p.hasMusic && _visible) {
      MusicPlayer.instance.setVolume(
        AppSettings.instance.feedMuted.value ? 0 : 1,
      );
    }
  }

  // v0.8: moments open on top -> pause (they are see-through, so the
  // card still looked "on screen")
  @override
  void onPageCoverChanged(bool covered) => _setVisible(_onScreen);

  void _setVisible(bool onScreen) {
    _onScreen = onScreen;
    final v = onScreen && !pageCovered;
    if (v == _visible || !mounted) return;
    setState(() => _visible = v);
    if (v) {
      if (p.hasMusic) {
        MusicPlayer.instance.play(
          _musicOwner,
          p.audioUrl,
          volume: AppSettings.instance.feedMuted.value ? 0 : 1,
        );
      }
      if (!_seenSent) {
        _seenTimer?.cancel();
        _seenTimer = Timer(const Duration(seconds: 1), () {
          if (!mounted || !_visible || _seenSent) return;
          _seenSent = true;
          widget.onSeen?.call();
        });
      }
    } else {
      _seenTimer?.cancel();
      if (p.hasMusic) MusicPlayer.instance.stop(_musicOwner);
    }
  }

  void _toggleMute() {
    final s = AppSettings.instance.feedMuted;
    s.value = !s.value;
  }

  Widget _item(MediaItem m, int i) {
    if (!m.isVideo) return MediaPhoto(url: m.url);
    return MediaVideo(
      item: m,
      active: _visible && i == _index,
      // music replaces the video sound
      muted: AppSettings.instance.feedMuted.value || p.hasMusic,
      mixWithOthers: p.hasMusic,
      onWatched: widget.onWatched,
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = p.items;
    final muted = AppSettings.instance.feedMuted.value;
    final screenH = MediaQuery.sizeOf(context).height;
    return VisibilityDetector(
      key: ValueKey('media-${p.id}'),
      // 60% of the card on screen, or it fills half the screen (tall cards)
      onVisibilityChanged: (info) => _setVisible(
        info.visibleFraction >= 0.6 ||
            (info.visibleFraction > 0 &&
                info.visibleBounds.height >= screenH * 0.5),
      ),
      child: AspectRatio(
        aspectRatio: cardAspectFor(p),
        child: GestureDetector(
          onTap: widget.onTap ?? (_hasSound ? _toggleMute : null),
          onDoubleTap: widget.onDoubleTap,
          onLongPress: widget.onLongPress,
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (items.length == 1)
                  _item(items.first, 0)
                else
                  PageView.builder(
                    controller: _pages,
                    itemCount: items.length,
                    onPageChanged: (i) => setState(() => _index = i),
                    itemBuilder: (context, i) => _item(items[i], i),
                  ),
                if (items.length > 1)
                  Positioned(
                    right: 10,
                    top: 10,
                    child: MediaPill(text: '${_index + 1}/${items.length}'),
                  ),
                if (items.length > 1)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 10,
                    child: IgnorePointer(
                      child: PageDots(count: items.length, index: _index),
                    ),
                  ),
                if (p.hasMusic)
                  Positioned(
                    left: 10,
                    bottom: items.length > 1 ? 26 : 10,
                    right: 60,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: MusicChip(name: p.audioName),
                    ),
                  ),
                if (_hasSound)
                  Positioned(
                    right: 10,
                    bottom: items.length > 1 ? 24 : 10,
                    child: GestureDetector(
                      key: const ValueKey('feed-mute'),
                      onTap: _toggleMute,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          muted ? Icons.volume_off : Icons.volume_up,
                          size: 17,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                if (widget.overlay != null) widget.overlay!,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "♪ Song name" label.
class MusicChip extends StatelessWidget {
  const MusicChip({super.key, required this.name, this.onTap});
  final String name;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.music_note, size: 14, color: Colors.white),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                name.isEmpty ? 'Music' : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small dark pill with text.
class MediaPill extends StatelessWidget {
  const MediaPill({super.key, required this.text, this.icon});
  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// Carousel dots. With many items only 9 dots around the current one show.
class PageDots extends StatelessWidget {
  const PageDots({super.key, required this.count, required this.index});
  final int count;
  final int index;

  static const int maxDots = 9;

  /// First and last dot index shown (inclusive).
  static (int, int) window(int count, int index) {
    if (count <= maxDots) return (0, count - 1);
    var start = index - maxDots ~/ 2;
    if (start < 0) start = 0;
    if (start > count - maxDots) start = count - maxDots;
    return (start, start + maxDots - 1);
  }

  @override
  Widget build(BuildContext context) {
    final (a, b) = window(count, index);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = a; i <= b; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 2.5),
            // dots at the edge of a moving window are smaller
            width: i == index
                ? 16
                : ((i == a && a > 0) || (i == b && b < count - 1) ? 4 : 6),
            height: (i == a && a > 0) || (i == b && b < count - 1) ? 4 : 6,
            decoration: BoxDecoration(
              color: i == index ? AppColors.lime : Colors.white54,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}
