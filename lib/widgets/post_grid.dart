import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/ui.dart';
import '../models/post.dart';
import '../screens/post/post_detail_screen.dart';
import 'video_thumb.dart';

class PostGridSliver extends StatelessWidget {
  const PostGridSliver({super.key, required this.posts});
  final List<Post> posts;

  @override
  Widget build(BuildContext context) {
    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, i) => _Tile(post: posts[i]),
        childCount: posts.length,
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.post});
  final Post post;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => openScreen(context, PostDetailScreen(post: post)),
      child: post.isVideo
          ? VideoThumb(post: post, playSize: 32, showBadge: false)
          : CachedNetworkImage(
              imageUrl: post.imageUrl,
              fit: BoxFit.cover,
              placeholder: (_, _) => ColoredBox(color: context.softFill),
              errorWidget: (_, _, _) => ColoredBox(color: context.softFill),
            ),
    );
  }
}
