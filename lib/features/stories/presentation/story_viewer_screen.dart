import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/services/app_settings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/net_image.dart';
import '../../editor/filters.dart';
import '../../profile/data/user_repository.dart';
import '../data/story_repository.dart';

/// Full-screen moment viewer: tap right = next, tap left = back,
/// hold = pause, swipe down = close. Plays photo and video moments.
class StoryViewerScreen extends StatefulWidget {
  const StoryViewerScreen({
    super.key,
    required this.groups,
    this.initialGroup = 0,
  });

  final List<StoryGroup> groups;
  final int initialGroup;

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen>
    with SingleTickerProviderStateMixin {
  static const _photoTime = Duration(seconds: 5);

  late int _g = widget.initialGroup.clamp(0, widget.groups.length - 1);
  late int _s = _firstUnseen(widget.groups[_g]);
  late final AnimationController _timer =
      AnimationController(vsync: this, duration: _photoTime)
        ..addStatusListener((st) {
          if (st == AnimationStatus.completed) _next();
        });

  VideoPlayerController? _video;
  bool _videoReady = false;
  bool _videoError = false;
  bool _paused = false;
  int _loadId = 0;

  StoryGroup get _group => widget.groups[_g];
  Story get _story => _group.stories[_s];

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
    super.dispose();
  }

  /// Start the current moment (photo timer or video).
  Future<void> _show() async {
    final id = ++_loadId;
    final st = _story;
    AppSettings.instance.markSeen(st.id);
    _timer.stop();
    _timer.value = 0;
    final old = _video;
    _video = null;
    _videoReady = false;
    _videoError = false;
    old?.dispose();

    if (!st.isVideo) {
      _timer.duration = _photoTime;
      if (!_paused) _timer.forward(from: 0);
      if (mounted) setState(() {});
      return;
    }

    if (mounted) setState(() {});
    final c = VideoPlayerController.networkUrl(Uri.parse(st.mediaUrl));
    _video = c;
    try {
      await c.initialize();
      if (!mounted || id != _loadId) return;
      final e = st.edits;
      final total = c.value.duration.inMilliseconds;
      final start = e.trimStartMs.clamp(0, total);
      var end = e.trimEndMs > 0 ? e.trimEndMs.clamp(start, total) : total;
      if (end - start > kMomentMaxMs) end = start + kMomentMaxMs;
      final len = (end - start).clamp(1000, kMomentMaxMs);
      await c.setVolume(e.muted ? 0 : 1);
      if (start > 0) await c.seekTo(Duration(milliseconds: start));
      _timer.duration = Duration(milliseconds: len);
      setState(() => _videoReady = true);
      if (!_paused) {
        c.play();
        _timer.forward(from: 0);
      }
    } catch (_) {
      if (!mounted || id != _loadId) return;
      setState(() => _videoError = true);
      _timer.duration = const Duration(seconds: 3);
      _timer.forward(from: 0);
    }
  }

  void _pause() {
    _paused = true;
    _timer.stop();
    _video?.pause();
  }

  void _resume() {
    _paused = false;
    if (_story.isVideo && !_videoReady && !_videoError) return;
    _timer.forward();
    _video?.play();
  }

  void _next() {
    if (_s < _group.stories.length - 1) {
      setState(() => _s++);
      _show();
    } else if (_g < widget.groups.length - 1) {
      setState(() {
        _g++;
        _s = _firstUnseen(_group);
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

  Future<void> _delete() async {
    _pause();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete this moment?'),
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
    if (ok == true) {
      await StoryRepository.instance.delete(_story);
      if (mounted) Navigator.of(context).maybePop();
    } else {
      _resume();
    }
  }

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
      return const Center(
        child: SizedBox(
          width: 34,
          height: 34,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    return Center(
      child: AspectRatio(
        aspectRatio: c.value.aspectRatio,
        child: applyMatrix(st.edits.filter, VideoPlayer(c)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mine = _group.authorId == UserRepository.instance.myUid;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: (d) {
          final w = MediaQuery.of(context).size.width;
          d.globalPosition.dx < w / 3 ? _prev() : _next();
        },
        onLongPressStart: (_) => _pause(),
        onLongPressEnd: (_) => _resume(),
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) Navigator.of(context).maybePop();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
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
                            name: _group.username,
                            size: 36,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            _group.username,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 8),
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
                        if (mine)
                          IconButton(
                            onPressed: _delete,
                            icon: const Icon(Icons.delete_outline),
                          ),
                        IconButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
