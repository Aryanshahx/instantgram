import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/share.dart';
import '../../../shared/models/post.dart';
import '../../../shared/navigation.dart';
import '../../profile/data/user_repository.dart';
import '../../../core/services/app_settings.dart';
import '../data/post_repository.dart';
import 'report_sheet.dart';

/// "..." menu for a post or clip.
/// [showAutoScroll] adds the "Auto scroll" switch (Clips screen).
Future<void> showPostMenu(
  BuildContext context,
  Post post, {
  VoidCallback? onDeleted,
  bool showAutoScroll = false,
}) {
  final mine = post.authorId == UserRepository.instance.myUid;
  final messenger = ScaffoldMessenger.of(context);
  final settings = AppSettings.instance;
  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListTileTheme.merge(
        visualDensity: VisualDensity.compact,
        iconColor: AppColors.textPrimary,
        titleTextStyle: const TextStyle(
          fontFamily: AppTheme.fontFamily,
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: AppColors.textPrimary,
        ),
        subtitleTextStyle: const TextStyle(
          fontFamily: AppTheme.fontFamily,
          fontSize: 12.5,
          color: AppColors.textSecondary,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showAutoScroll)
              ValueListenableBuilder<bool>(
                valueListenable: settings.clipsAutoScroll,
                builder: (context, on, child) => SwitchListTile(
                  secondary: const Icon(Icons.swipe_up_outlined),
                  title: const Text('Auto scroll'),
                  subtitle: const Text('Play the next clip when one ends'),
                  value: on,
                  activeThumbColor: Colors.black,
                  activeTrackColor: AppColors.lime,
                  onChanged: settings.setClipsAutoScroll,
                ),
              ),
            if (mine)
              ListTile(
                leading: Icon(
                  post.pinned ? Icons.push_pin_outlined : Icons.push_pin,
                ),
                title: Text(
                  post.pinned ? 'Unpin from profile' : 'Pin to profile',
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await PostRepository.instance.setPinned(post, !post.pinned);
                  } catch (e) {
                    messenger.showSnackBar(
                      SnackBar(content: Text(friendlyError(e))),
                    );
                  }
                },
              ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('Share'),
              onTap: () {
                Navigator.pop(ctx);
                sharePost(post);
              },
            ),
            if (!mine)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text('View @${post.authorUsername}'),
                onTap: () {
                  Navigator.pop(ctx);
                  openProfile(context, post.authorId);
                },
              ),
            if (!mine)
              ListTile(
                leading: const Icon(Icons.flag_outlined, color: AppColors.like),
                title: Text(
                  'Report ${post.isClip ? 'clip' : 'post'}',
                  style: const TextStyle(color: AppColors.like),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  showReportSheet(context, post);
                },
              ),
            if (mine)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: AppColors.like,
                ),
                title: const Text(
                  'Delete',
                  style: TextStyle(color: AppColors.like),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: Text(
                        'Delete this ${post.isClip ? 'clip' : 'post'}?',
                      ),
                      content: const Text('This cannot be undone.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(d, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(d, true),
                          child: const Text(
                            'Delete',
                            style: TextStyle(color: AppColors.like),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (ok != true) return;
                  try {
                    await PostRepository.instance.delete(post);
                    onDeleted?.call();
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Deleted')),
                    );
                  } catch (e) {
                    messenger.showSnackBar(
                      SnackBar(content: Text(friendlyError(e))),
                    );
                  }
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}
