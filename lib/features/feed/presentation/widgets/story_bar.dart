import 'package:flutter/material.dart';

import '../../../../shared/models/post.dart';
import '../../../../shared/widgets/avatar.dart';

class StoryBar extends StatelessWidget {
  const StoryBar({
    super.key,
    required this.myAvatarUrl,
    required this.myName,
    required this.stories,
    this.onAddStory,
  });

  final String myAvatarUrl;
  final String myName;
  final List<Story> stories;
  final VoidCallback? onAddStory;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 112,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        itemCount: stories.length + 1,
        separatorBuilder: (context, index) => const SizedBox(width: 14),
        itemBuilder: (context, i) {
          if (i == 0) {
            return _StoryItem(
              label: 'You',
              onTap: onAddStory,
              child: Avatar(
                url: myAvatarUrl,
                name: myName,
                size: 70,
                showPlus: true,
                onPlusTap: onAddStory,
              ),
            );
          }
          final s = stories[i - 1];
          return _StoryItem(
            label: s.username,
            child: Avatar(
              url: s.avatarUrl,
              name: s.username,
              size: 62,
              ring: true,
            ),
          );
        },
      ),
    );
  }
}

class _StoryItem extends StatelessWidget {
  const _StoryItem({required this.label, required this.child, this.onTap});

  final String label;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 74,
        child: Column(
          children: [
            SizedBox(height: 74, child: Center(child: child)),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
