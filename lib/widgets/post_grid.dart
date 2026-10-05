import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../core/responsive.dart';
import '../core/ui.dart';
import '../models/post.dart';
import '../screens/post/post_detail_screen.dart';
import '../screens/reels/reels_screen.dart';
import '../services/safety_service.dart';
import 'post_details_sheet.dart' show compactCount;
import 'post_media.dart';
import 'reel_actions.dart';

/// Masonry of posts. Every tile has the real proportions of its photo or clip (square corners).
class PostGridSliver extends StatelessWidget {
  const PostGridSliver({
    super.key,
    required this.posts,
    this.showViews = false,
    this.inline = false,
  });
  final List<Post> posts;

  /// Show how many people watched (profile pages) instead of the likes.
  final bool showViews;

  /// Clips play by themselves while they are on screen (Explore).
  final bool inline;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      sliver: SliverLayoutBuilder(
        builder: (context, c) => SliverMasonryGrid.count(
          crossAxisCount: gridColumnsFor(c.crossAxisExtent),
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          childCount: posts.length,
          itemBuilder: (context, i) =>
              _Tile(post: posts[i], showViews: showViews, inline: inline),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.post,
    this.showViews = false,
    this.inline = false,
  });
  final Post post;
  final bool showViews;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => post.isClip
          ? openClips(context, post)
          : openScreen(context, PostDetailScreen(post: post)),
      child: Stack(
        children: [
          PostMedia(
            post: post,
            playSize: 40,
            inline: inline && post.isVideo,
            showSound: false,
          ),
          if (post.isCarousel)
            const Positioned(
              right: 8,
              top: 8,
              child: IgnorePointer(
                child: Icon(
                  Icons.collections_rounded,
                  size: 18,
                  color: Colors.white,
                  shadows: kReelShadow,
                ),
              ),
            ),
          Positioned(
            left: 8,
            bottom: 6,
            child: IgnorePointer(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    showViews
                        ? Icons.visibility_rounded
                        : Icons.favorite_rounded,
                    size: 16,
                    color: Colors.white,
                    shadows: kReelShadow,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    !showViews &&
                            !SafetyService.instance.showsNumber(post, post.hideLikes)
                        ? '-'
                        : compactCount(
                            showViews ? post.viewCount : post.likeCount,
                          ),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      shadows: kReelShadow,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
