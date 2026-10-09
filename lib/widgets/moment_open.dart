import 'package:flutter/material.dart';

import '../core/ui.dart';
import '../models/story.dart';
import '../screens/story/story_viewer.dart';
import '../services/story_service.dart';

/// Test hook: the moments that can be watched (instead of loading them).
Future<List<StoryGroup>> Function()? debugMomentGroups;

/// Test hook: called instead of opening the viewer (with the person's group).
void Function(StoryGroup group)? debugOpenMoments;

/// Opens the moments of [uid] when they have any. Returns false when there is nothing to
/// watch (the caller decides what a tap does then).
Future<bool> openMomentsOf(BuildContext context, String uid) async {
  List<StoryGroup> groups;
  try {
    groups = await (debugMomentGroups ?? StoryService.instance.load)();
  } catch (_) {
    return false;
  }
  final i = groups.indexWhere((g) => g.authorId == uid && g.stories.isNotEmpty);
  if (i < 0) return false;
  final hook = debugOpenMoments;
  if (hook != null) {
    hook(groups[i]);
    return true;
  }
  if (!context.mounted) return true;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => StoryViewer(groups: [groups[i]], initialIndex: 0),
    ),
  );
  return true;
}

/// Shows a short note when a picture is tapped but there is no moment.
void noMomentNote(BuildContext context, String username) =>
    showToast(context, '@$username has no moment right now.');
