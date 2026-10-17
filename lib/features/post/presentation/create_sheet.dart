import 'package:flutter/material.dart';

import '../../../core/services/media_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/models/post.dart';
import '../../editor/edit_models.dart';
import '../../editor/media_editor_screen.dart';

export '../../editor/edit_models.dart' show ComposeMode;

/// Bottom sheet opened by the "+" button.
Future<void> showCreateSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) {
      Future<void> start(ComposeMode mode) async {
        Navigator.pop(ctx);
        await startCompose(context, mode);
      }

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 12),
                child: Text(
                  'Create',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
              ),
              _CreateOption(
                icon: Icons.grid_view_rounded,
                title: 'Post',
                subtitle: 'Photos and videos on your profile',
                onTap: () => start(ComposeMode.photo),
              ),
              _CreateOption(
                icon: Icons.smart_display_outlined,
                title: 'Clip',
                subtitle: 'Short videos and photos, full screen',
                onTap: () => start(ComposeMode.clip),
              ),
              _CreateOption(
                icon: Icons.add_circle_outline,
                title: 'Moment',
                subtitle: 'Photos or videos for 24 hours',
                onTap: () => start(ComposeMode.story),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Pick media -> editor -> share screen.
/// Posts and clips can mix photos and videos (no limit).
/// v0.9: [reply] = the new clip / post answers a comment.
/// Music update: [audio] = "Use this audio" (the editor starts with it).
Future<void> startCompose(
  BuildContext context,
  ComposeMode mode, {
  ReplyRef? reply,
  PickedAudio? audio,
}) async {
  final kind = mode == ComposeMode.story ? PickKind.moment : PickKind.mixed;
  ComposeReply.pending = mode == ComposeMode.story ? null : reply;
  try {
    final media = await MediaService.instance.pickForCreate(context, kind);
    if (media.isEmpty || !context.mounted) return;
    await openEditor(context, media, mode, audio: audio);
  } finally {
    ComposeReply.pending = null;
  }
}

/// The comment the clip / post being made answers (v0.9).
class ComposeReply {
  ComposeReply._();
  static ReplyRef? pending;
}

class _CreateOption extends StatelessWidget {
  const _CreateOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: const BorderSide(color: AppColors.border),
        ),
        child: ListTile(
          onTap: onTap,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          leading: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.lime,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: Colors.black),
          ),
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
          ),
          subtitle: Text(
            subtitle,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
        ),
      ),
    );
  }
}
