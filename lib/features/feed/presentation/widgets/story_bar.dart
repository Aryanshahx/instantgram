import 'package:flutter/material.dart';

import '../../../../shared/models/post.dart';
import '../../../../shared/models/user_profile.dart';
import '../../../../shared/widgets/avatar.dart';
import '../../../../core/services/app_settings.dart';
import '../../../stories/data/moments_index.dart';
import '../../../stories/presentation/story_extras.dart';

class StoryBar extends StatelessWidget {
  const StoryBar({
    super.key,
    required this.me,
    required this.myUid,
    required this.onAddStory,
    this.allowed = const <String>{},
  });

  /// Only moments from these people (I follow them or they are famous).
  final Set<String> allowed;

  final UserProfile? me;
  final String myUid;
  final VoidCallback onAddStory;

  @override
  Widget build(BuildContext context) {
    final index = MomentsIndex.instance;
    return ListenableBuilder(
      listenable: index.listenable,
      builder: (context, _) {
        final ordered = index.rowGroups(myUid, allowed);
        final mine = ordered.where((g) => g.authorId == myUid).toList();
        final others = ordered.where((g) => g.authorId != myUid).toList();

        void open(StoryGroup g) =>
            openStoryViewer(context, ordered, ordered.indexOf(g));

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
                    seen: hasMine && index.allSeen(mine.first),
                    showPlus: true,
                    onPlusTap: onAddStory,
                  ),
                );
              }
              final g = others[i - 1];
              return _StoryItem(
                label: g.username,
                onTap: () => open(g),
                // v0.15: hold = small preview (not counted as a view)
                onLongPress: () => showStoryPreview(
                  context,
                  g,
                  index: () {
                    final i = g.stories.indexWhere(
                      (s) => !AppSettings.instance.isSeen(s.id),
                    );
                    return i < 0 ? 0 : i;
                  }(),
                  onOpen: () => open(g),
                ),
                child: Avatar(
                  url: g.photoUrl,
                  photoUid: g.authorId,
                  name: g.username,
                  size: 62,
                  ring: true,
                  seen: index.allSeen(g),
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
  const _StoryItem({
    required this.label,
    required this.child,
    this.onTap,
    this.onLongPress,
  });

  final String label;
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
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
