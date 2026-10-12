import 'package:flutter/material.dart';

import '../../../../shared/models/post.dart';
import '../../../../shared/models/user_profile.dart';
import '../../../../shared/widgets/avatar.dart';
import '../../../stories/data/story_repository.dart';
import '../../../stories/presentation/story_viewer_screen.dart';

class StoryBar extends StatelessWidget {
  const StoryBar({
    super.key,
    required this.me,
    required this.myUid,
    required this.onAddStory,
  });

  final UserProfile? me;
  final String myUid;
  final VoidCallback onAddStory;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<StoryGroup>>(
      stream: StoryRepository.instance.active(),
      builder: (context, snap) {
        final all = snap.data ?? const <StoryGroup>[];
        final mine = all.where((g) => g.authorId == myUid).toList();
        final others = all.where((g) => g.authorId != myUid).toList();
        final ordered = [...mine, ...others];

        void open(StoryGroup g) {
          Navigator.of(context).push(
            PageRouteBuilder(
              opaque: false,
              pageBuilder: (_, a, b) => StoryViewerScreen(
                groups: ordered,
                initialGroup: ordered.indexOf(g),
              ),
              transitionsBuilder: (_, a, b, child) =>
                  FadeTransition(opacity: a, child: child),
            ),
          );
        }

        return SizedBox(
          height: 112,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            itemCount: others.length + 1,
            separatorBuilder: (context, index) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              if (i == 0) {
                final hasMine = mine.isNotEmpty;
                return _StoryItem(
                  label: 'You',
                  onTap: hasMine ? () => open(mine.first) : onAddStory,
                  child: Avatar(
                    url: me?.photoUrl ?? '',
                    name: me?.displayName ?? '',
                    size: hasMine ? 62 : 70,
                    ring: hasMine,
                    showPlus: true,
                    onPlusTap: onAddStory,
                  ),
                );
              }
              final g = others[i - 1];
              return _StoryItem(
                label: g.username,
                onTap: () => open(g),
                child: Avatar(
                  url: g.photoUrl,
                  name: g.username,
                  size: 62,
                  ring: true,
                ),
              );
            },
          ),
        );
      },
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
      behavior: HitTestBehavior.opaque,
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
