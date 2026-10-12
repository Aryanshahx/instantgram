import 'package:flutter/material.dart';

import '../../../core/services/media_service.dart';
import '../../../core/theme/app_colors.dart';
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
                subtitle: 'Share up to 10 photos on your profile',
                onTap: () => start(ComposeMode.photo),
              ),
              _CreateOption(
                icon: Icons.smart_display_outlined,
                title: 'Clip',
                subtitle: 'Share a short video (up to 90s)',
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
Future<void> startCompose(BuildContext context, ComposeMode mode) async {
  final kind = switch (mode) {
    ComposeMode.photo => PickKind.photos,
    ComposeMode.clip => PickKind.video,
    ComposeMode.story => PickKind.mixed,
  };
  var media = await MediaService.instance.pickForCreate(context, kind);
  if (media.isEmpty || !context.mounted) return;
  // posts = photos only, clips = one video only
  if (mode == ComposeMode.photo) {
    media = media.where((m) => !m.isVideo).toList();
  } else if (mode == ComposeMode.clip) {
    media = media.where((m) => m.isVideo).take(1).toList();
  }
  if (media.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          mode == ComposeMode.clip
              ? 'Clips need a video'
              : 'Posts need photos (use Clip for videos)',
        ),
      ),
    );
    return;
  }
  await openEditor(context, media, mode);
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
