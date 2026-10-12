import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/time_ago.dart';
import '../models/post.dart';
import 'empty_state.dart';
import 'net_image.dart';

/// Background used for clips (no thumbnail yet).
class ClipCover extends StatelessWidget {
  const ClipCover({super.key, required this.post, this.big = false});
  final Post post;
  final bool big;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2E2A5C), Color(0xFF15162A)],
        ),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.movie_creation,
            size: big ? 64 : 36,
            color: Colors.white.withValues(alpha: 0.3),
          ),
          if (post.caption.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              post.caption,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: big ? 16 : 12,
                color: Colors.white.withValues(alpha: 0.75),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class PostTile extends StatelessWidget {
  const PostTile({super.key, required this.post, required this.onTap});
  final Post post;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          post.isClip ? ClipCover(post: post) : NetImage(post.mediaUrl),
          if (post.pinned)
            const Positioned(
              top: 6,
              left: 6,
              child: Icon(Icons.push_pin, size: 18, color: Colors.white),
            ),
          if (post.isClip)
            Positioned(
              left: 6,
              bottom: 6,
              child: Row(
                children: [
                  const Icon(Icons.play_arrow_rounded,
                      size: 18, color: Colors.white),
                  Text(
                    compactCount(post.viewsCount),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 3-column square grid (profile / saved).
class PostGrid extends StatelessWidget {
  const PostGrid({
    super.key,
    required this.posts,
    required this.onTap,
    required this.emptyIcon,
    required this.emptyTitle,
    this.emptySubtitle,
  });

  final List<Post> posts;
  final void Function(int index) onTap;
  final IconData emptyIcon;
  final String emptyTitle;
  final String? emptySubtitle;

  @override
  Widget build(BuildContext context) {
    if (posts.isEmpty) {
      return ListView(
        padding: const EdgeInsets.only(bottom: 110),
        children: [
          EmptyState(icon: emptyIcon, title: emptyTitle, subtitle: emptySubtitle),
        ],
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 110),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        childAspectRatio: 0.8,
      ),
      itemCount: posts.length,
      itemBuilder: (context, i) => ColoredBox(
        color: AppColors.surface,
        child: PostTile(post: posts[i], onTap: () => onTap(i)),
      ),
    );
  }
}
