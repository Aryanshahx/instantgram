import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/errors.dart';
import '../../core/utils/time_ago.dart';
import '../../shared/models/post.dart';
import '../post/data/post_repository.dart';
import 'post_insights_screen.dart';

/// Hold on your own post / clip (in a grid): Analytics and Pin.
Future<void> showOwnerQuickSheet(BuildContext context, Post post) {
  final messenger = ScaffoldMessenger.of(context);
  const style = TextStyle(
    fontFamily: AppTheme.fontFamily,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );
  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
            child: Row(
              children: [
                Icon(
                  post.isClip ? Icons.movie_outlined : Icons.photo_outlined,
                  size: 18,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${post.isClip ? 'Clip' : 'Post'} · '
                    '${compactCount(post.viewsCount)} views · '
                    '${compactCount(post.likesCount)} likes',
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            key: const ValueKey('owner-analytics'),
            leading: const Icon(Icons.insights_outlined),
            title: const Text('Analytics', style: style),
            subtitle: const Text(
              'Overview, engagement and audience',
              style: TextStyle(color: AppColors.textSecondary),
            ),
            onTap: () {
              Navigator.pop(ctx);
              openPostInsights(context, post);
            },
          ),
          ListTile(
            key: const ValueKey('owner-pin'),
            leading: Icon(
              post.pinned ? Icons.push_pin_outlined : Icons.push_pin,
            ),
            title: Text(
              post.pinned ? 'Unpin from profile' : 'Pin to profile',
              style: style,
            ),
            onTap: () async {
              Navigator.pop(ctx);
              try {
                await PostRepository.instance.setPinned(post, !post.pinned);
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      post.pinned ? 'Unpinned' : 'Pinned to profile',
                    ),
                  ),
                );
              } catch (e) {
                messenger.showSnackBar(
                  SnackBar(content: Text(friendlyError(e))),
                );
              }
            },
          ),
          const SizedBox(height: 6),
        ],
      ),
    ),
  );
}
