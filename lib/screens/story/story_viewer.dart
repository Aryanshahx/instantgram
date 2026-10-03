import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../../core/app_events.dart';
import '../../core/errors.dart';
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
    required this.onFinished,
    required this.onBackFromFirst,
    required this.onClose,
  });

  final StoryGroup group;
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

  bool get _mine => widget.group.authorId == UserService.instance.myUid;
  Story get _story => widget.group.stories[_i];

  @override
  void initState() {
    super.initState();
    _anim.addStatusListener((s) {
      if (s == AnimationStatus.completed) _next();
    });
    _anim.forward();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _next() {
    if (_i < widget.group.stories.length - 1) {
      setState(() => _i++);
      _anim.forward(from: 0);
    } else {
      widget.onFinished();
    }
  }

  void _previous() {
    if (_i > 0) {
      setState(() => _i--);
      _anim.forward(from: 0);
    } else {
      widget.onBackFromFirst();
      _anim.forward(from: 0);
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
      if (mounted) _anim.forward();
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
      if (mounted) {
        setState(() {});
        _anim.forward(from: 0);
      }
    } catch (e) {
      if (mounted) {
        showToast(context, friendlyError(e));
        _anim.forward();
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
      onLongPressStart: (_) => _anim.stop(),
      onLongPressEnd: (_) => _anim.forward(),
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 300) widget.onClose();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            key: ValueKey(story.id),
            imageUrl: story.imageUrl,
            fit: BoxFit.contain,
            placeholder: (_, _) =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            errorWidget: (_, _, _) => const Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: Colors.white54,
                size: 48,
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
