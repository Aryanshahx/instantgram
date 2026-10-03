import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../core/responsive.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../models/post.dart';
import '../screens/post/post_detail_screen.dart';
import 'video_thumb.dart';

/// Two-column masonry of posts (tiles have varied heights).
class PostGridSliver extends StatelessWidget {
  const PostGridSliver({super.key, required this.posts});
  final List<Post> posts;

  static const _ratios = [0.82, 1.0, 0.72, 0.92, 1.12, 0.78];

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverLayoutBuilder(
        builder: (context, c) => SliverMasonryGrid.count(
          crossAxisCount: gridColumnsFor(c.crossAxisExtent),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childCount: posts.length,
          itemBuilder: (context, i) =>
              _Tile(post: posts[i], ratio: _ratios[i % _ratios.length]),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.post, required this.ratio});
  final Post post;
  final double ratio;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => openScreen(context, PostDetailScreen(post: post)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: AspectRatio(
          aspectRatio: ratio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (post.isVideo)
                VideoThumb(post: post, playSize: 36, showBadge: false)
              else
                CachedNetworkImage(
                  imageUrl: post.imageUrl,
                  fit: BoxFit.cover,
                  placeholder: (_, _) => ColoredBox(color: context.cardHigh),
                  errorWidget: (_, _, _) => ColoredBox(color: context.cardHigh),
                ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black54],
                    stops: [0.6, 1],
                  ),
                ),
              ),
              Positioned(
                left: 8,
                bottom: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.bolt_rounded,
                        size: 14,
                        color: AppTheme.volt,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '${post.likeCount}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
