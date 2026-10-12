import 'package:flutter/material.dart';

import '../../../core/services/media_service.dart';
import '../../../core/theme/app_colors.dart';
import 'create_post_screen.dart';

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
                subtitle: 'Share a photo on your profile',
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
                subtitle: 'A photo that disappears after 24 hours',
                onTap: () => start(ComposeMode.story),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Pick media and open the compose screen.
Future<void> startCompose(BuildContext context, ComposeMode mode) async {
  final file = await MediaService.instance.pick(
    context,
    video: mode == ComposeMode.clip,
  );
  if (file == null || !context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => CreatePostScreen(file: file, mode: mode)),
  );
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
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
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
