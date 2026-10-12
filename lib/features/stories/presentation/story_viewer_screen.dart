import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/net_image.dart';
import '../../profile/data/user_repository.dart';
import '../data/story_repository.dart';

/// Full-screen moment (story) viewer: tap right = next, tap left = back,
/// hold = pause, swipe down = close.
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
  late int _g = widget.initialGroup.clamp(0, widget.groups.length - 1);
  int _s = 0;
  late final AnimationController _timer = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 5),
  )..addStatusListener((st) {
      if (st == AnimationStatus.completed) _next();
    });

  StoryGroup get _group => widget.groups[_g];
  Story get _story => _group.stories[_s];

  @override
  void initState() {
    super.initState();
    _timer.forward();
  }

  @override
  void dispose() {
    _timer.dispose();
    super.dispose();
  }

  void _restart() => _timer.forward(from: 0);

  void _next() {
    if (_s < _group.stories.length - 1) {
      setState(() => _s++);
      _restart();
    } else if (_g < widget.groups.length - 1) {
      setState(() {
        _g++;
        _s = 0;
      });
      _restart();
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
    _restart();
  }

  Future<void> _delete() async {
    _timer.stop();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete this moment?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Delete',
                  style: TextStyle(color: AppColors.like))),
        ],
      ),
    );
    if (ok == true) {
      await StoryRepository.instance.delete(_story);
      if (mounted) Navigator.of(context).maybePop();
    } else {
      _timer.forward();
    }
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
        onLongPressStart: (_) => _timer.stop(),
        onLongPressEnd: (_) => _timer.forward(),
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) Navigator.of(context).maybePop();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            NetImage(_story.mediaUrl, fit: BoxFit.contain),
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
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 2),
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
                            Navigator.of(context).pop();
                            openProfile(context, uid);
                          },
                          child: Avatar(
                            url: _group.photoUrl,
                            name: _group.username,
                            size: 36,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _group.username,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          timeAgo(_story.createdAt),
                          style: const TextStyle(color: Colors.white70),
                        ),
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
