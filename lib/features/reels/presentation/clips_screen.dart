import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/data/mock_data.dart';
import '../../../shared/models/post.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/net_image.dart';

class ClipsScreen extends StatefulWidget {
  const ClipsScreen({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<ClipsScreen> createState() => _ClipsScreenState();
}

class _ClipsScreenState extends State<ClipsScreen> {
  late final PageController _pageCtrl = PageController(
    initialPage: widget.initialIndex,
  );
  late int _current = widget.initialIndex;
  bool _muted = false;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clips = MockData.clips;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              // Top bar
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
                  ],
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _pageCtrl,
                  scrollDirection: Axis.vertical,
                  itemCount: clips.length,
                  onPageChanged: (i) => setState(() => _current = i),
                  itemBuilder: (context, i) => ClipPlayer(
                    clip: clips[i],
                    active: i == _current,
                    muted: _muted,
                    onToggleMute: () => setState(() => _muted = !_muted),
                  ),
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
  });

  final ClipItem clip;
  final bool active;
  final bool muted;
  final VoidCallback onToggleMute;

  @override
  State<ClipPlayer> createState() => _ClipPlayerState();
}

class _ClipPlayerState extends State<ClipPlayer> {
  late final VideoPlayerController _ctrl;
  bool _ready = false;
  bool _failed = false;
  bool _liked = false;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.clip.videoUrl));
    _ctrl.setLooping(true);
    _ctrl
        .initialize()
        .then((_) {
          if (!mounted) return;
          setState(() => _ready = true);
          _ctrl.setVolume(widget.muted ? 0 : 1);
          if (widget.active) _ctrl.play();
        })
        .catchError((Object _) {
          if (mounted) setState(() => _failed = true);
        });
  }

  @override
  void didUpdateWidget(covariant ClipPlayer old) {
    super.didUpdateWidget(old);
    if (!_ready) return;
    if (widget.active != old.active) {
      widget.active ? _ctrl.play() : _ctrl.pause();
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

  @override
  Widget build(BuildContext context) {
    final c = widget.clip;
    return Column(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: _togglePlay,
            onDoubleTap: () => setState(() => _liked = true),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Cover until the video is ready
                if (!_ready) NetImage(c.coverUrl),
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
                // Bottom gradient
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
                // Right action column
                Positioned(
                  right: 10,
                  bottom: 20,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Action(
                        icon: _liked ? Icons.favorite : Icons.favorite_border,
                        color: _liked ? AppColors.like : Colors.white,
                        label: compactCount(c.likes + (_liked ? 1 : 0)),
                        onTap: () => setState(() => _liked = !_liked),
                      ),
                      _Action(
                        icon: Icons.chat_bubble_outline,
                        label: compactCount(c.comments),
                        onTap: () {},
                      ),
                      _Action(
                        icon: Icons.repeat,
                        label: compactCount(c.reposts),
                        onTap: () {},
                      ),
                      _Action(
                        icon: _saved ? Icons.bookmark : Icons.bookmark_border,
                        label: 'Save',
                        onTap: () => setState(() => _saved = !_saved),
                      ),
                      _Action(
                        icon: Icons.ios_share,
                        label: 'Share',
                        onTap: () {},
                      ),
                      _Action(
                        icon: Icons.auto_graph,
                        label: 'Insights',
                        onTap: () {},
                      ),
                      _Action(
                        icon: widget.muted ? Icons.volume_off : Icons.volume_up,
                        label: widget.muted ? 'Unmute' : 'Mute',
                        onTap: widget.onToggleMute,
                      ),
                    ],
                  ),
                ),
                // Author
                Positioned(
                  left: 16,
                  bottom: 18,
                  right: 90,
                  child: Row(
                    children: [
                      Avatar(url: c.avatarUrl, name: c.username, size: 40),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          c.username,
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
              ],
            ),
          ),
        ),
        // Caption + progress
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
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(
          width: 64,
          child: Column(
            children: [
              Icon(
                icon,
                size: 30,
                color: color,
                shadows: const [Shadow(blurRadius: 8, color: Colors.black54)],
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
