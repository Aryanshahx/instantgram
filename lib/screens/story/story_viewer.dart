import 'package:flutter/material.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../../core/app_events.dart';
import '../../core/errors.dart';
import '../../core/story_images.dart';
import '../../core/ui.dart';
import '../../models/story.dart';
import '../../services/story_service.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';

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
              ? widget.groups[i + 1].stories.first.imageUrl
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

  /// Loads the current picture, then starts its timer. The next pictures load meanwhile.
  Future<void> _prepare() async {
    final index = _i;
    final story = _story;
    if (_loaded || _failed) {
      setState(() {
        _loaded = false;
        _failed = false;
      });
    }
    _anim.stop();
    _anim.value = 0;
    var failed = false;
    try {
      await precacheImage(storyImageProvider(context, story.imageUrl), context);
    } catch (_) {
      failed = true;
    }
    if (!mounted || index != _i) return;
    setState(() {
      _loaded = true;
      _failed = failed;
    });
    if (!_holding) _anim.forward(from: 0);
    // warm the next picture (this person's, or the next person's first)
    if (_i + 1 < widget.group.stories.length) {
      warmStoryImage(context, widget.group.stories[_i + 1].imageUrl);
      if (_i + 2 < widget.group.stories.length) {
        warmStoryImage(context, widget.group.stories[_i + 2].imageUrl);
      }
    } else if (widget.nextFirstUrl != null) {
      warmStoryImage(context, widget.nextFirstUrl!);
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
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
    final ok = await confirm(
      context,
      title: 'Delete moment?',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) {
      if (mounted && _loaded) _anim.forward();
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
      },
      onLongPressEnd: (_) {
        _holding = false;
        if (_loaded) _anim.forward();
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
            Image(
              key: ValueKey(story.id),
              image: storyImageProvider(context, story.imageUrl),
              fit: BoxFit.contain,
              gaplessPlayback: true,
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
                      Text(
                        widget.group.username,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        timeago.format(story.createdAt, locale: 'en_short'),
                        style: const TextStyle(color: Colors.white70),
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
