import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/post.dart';
import 'reel_actions.dart';

/// Thumbnail of a video post (a cheap image; no player is created in lists).
/// Just the picture and a plain play icon: no duration, no button background.
class VideoThumb extends StatelessWidget {
  const VideoThumb({
    super.key,
    required this.post,
    this.playSize = 56,
    this.fit = BoxFit.cover,
  });

  final Post post;
  final double playSize;

  /// cover fills the box; contain always shows the whole frame.
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final placeholder = DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1B1F2B), Color(0xFF3A3470)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          Icons.movie_rounded,
          color: Colors.white24,
          size: playSize * 1.2,
        ),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        if (post.thumbnailUrl.isEmpty)
          placeholder
        else
          CachedNetworkImage(
            imageUrl: post.thumbnailUrl,
            fit: fit,
            placeholder: (_, _) => placeholder,
            errorWidget: (_, _, _) => placeholder,
          ),
        Center(
          child: Icon(
            Icons.play_arrow_rounded,
            color: Colors.white,
            size: playSize,
            shadows: kReelShadow,
          ),
        ),
      ],
    );
  }
}
