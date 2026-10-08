import 'package:flutter/material.dart';

import '../core/story_images.dart';
import '../models/story.dart';
import 'avatar.dart';
import 'story_overlays.dart';

/// Long-press a ring: a small look at that person's moments that does not put you in their
/// viewer list. Tap the right side for the next one, the left for the previous one; "Open"
/// watches them normally (that does count).
Future<void> showStoryPeek(
  BuildContext context,
  StoryGroup group, {
  VoidCallback? onOpen,
}) => showDialog<void>(
  context: context,
  barrierColor: Colors.black87,
  builder: (_) => StoryPeek(group: group, onOpen: onOpen),
);

class StoryPeek extends StatefulWidget {
  const StoryPeek({super.key, required this.group, this.onOpen});

  final StoryGroup group;
  final VoidCallback? onOpen;

  @override
  State<StoryPeek> createState() => _StoryPeekState();
}

class _StoryPeekState extends State<StoryPeek> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    final stories = widget.group.stories;
    final story = stories[_i.clamp(0, stories.length - 1)];
    final size = MediaQuery.of(context).size;
    // fits a phone upright, a phone sideways and a tablet (room for the name and buttons)
    final byHeight = (size.height - 190) * 9 / 16;
    final w = (size.width * 0.62)
        .clamp(120.0, 340.0)
        .clamp(80.0, byHeight < 80 ? 80.0 : byHeight);
    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                UserAvatar(
                  url: widget.group.photoUrl,
                  name: widget.group.username,
                  radius: 14,
                ),
                const SizedBox(width: 8),
                Text(
                  widget.group.username,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            GestureDetector(
              key: const ValueKey('storyPeek'),
              onTapUp: (d) {
                setState(() {
                  if (d.localPosition.dx < w / 3) {
                    if (_i > 0) _i--;
                  } else if (_i < stories.length - 1) {
                    _i++;
                  }
                });
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: SizedBox(
                  width: w,
                  height: w * 16 / 9,
                  child: ColoredBox(
                    color: Colors.black,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        StoryCanvas(
                          media: story.coverUrl.isEmpty
                              ? const SizedBox.shrink()
                              : Image(
                                  key: ValueKey(story.id),
                                  image: storyImageProvider(
                                    context,
                                    story.coverUrl,
                                  ),
                                  fit: BoxFit.contain,
                                  gaplessPlayback: true,
                                  errorBuilder: (_, _, _) => const Icon(
                                    Icons.image_not_supported_outlined,
                                    color: Colors.white38,
                                  ),
                                ),
                          overlays: [
                            for (final o in story.overlays)
                              if (!o.isImage) o,
                          ],
                        ),
                        if (story.isVideo)
                          const Positioned(
                            right: 10,
                            top: 10,
                            child: Icon(
                              Icons.videocam_rounded,
                              color: Colors.white70,
                            ),
                          ),
                        Positioned(
                          left: 8,
                          right: 8,
                          top: 6,
                          child: Row(
                            children: [
                              for (var k = 0; k < stories.length; k++)
                                Expanded(
                                  child: Container(
                                    height: 3,
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: k == _i
                                          ? Colors.white
                                          : Colors.white38,
                                      borderRadius: BorderRadius.circular(2),
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
              ),
            ),
            const SizedBox(height: 10),
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.visibility_off_outlined,
                  color: Colors.white70,
                  size: 16,
                ),
                SizedBox(width: 6),
                Text(
                  'Peek: you are not added to their viewers',
                  key: ValueKey('peekHint'),
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    'Close',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
                if (widget.onOpen != null)
                  TextButton(
                    key: const ValueKey('peekOpen'),
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onOpen!();
                    },
                    child: const Text(
                      'Watch (counts as a view)',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
