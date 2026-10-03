import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/media_url.dart';
import '../core/theme.dart';
import '../models/post.dart';

/// Thumbnail of a video post (a cheap image; no player is created in lists).
class VideoThumb extends StatelessWidget {
  const VideoThumb({
    super.key,
    required this.post,
    this.playSize = 56,
    this.showBadge = true,
  });

  final Post post;
  final double playSize;

  /// Shows the duration chip.
  final bool showBadge;

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
            fit: BoxFit.cover,
            placeholder: (_, _) => placeholder,
            errorWidget: (_, _, _) => placeholder,
          ),
        Center(
          child: Container(
            width: playSize,
            height: playSize,
            decoration: const BoxDecoration(
              color: Colors.black45,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: playSize * 0.7,
            ),
          ),
        ),
        if (showBadge && post.videoDuration > 0)
          Positioned(
            top: 10,
            right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.volt,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                formatDuration(post.videoDuration),
                style: const TextStyle(
                  color: AppTheme.ink,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
