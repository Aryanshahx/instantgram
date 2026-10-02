import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/post.dart';
import '../models/video_link.dart';

IconData platformIcon(VideoPlatform? p) {
  switch (p) {
    case VideoPlatform.youtube:
      return Icons.smart_display;
    case VideoPlatform.tiktok:
      return Icons.music_note;
    case VideoPlatform.instagram:
      return Icons.camera_alt_outlined;
    case null:
      return Icons.play_circle_outline;
  }
}

List<Color> _platformColors(VideoPlatform? p) {
  switch (p) {
    case VideoPlatform.youtube:
      return const [Color(0xFFFF0000), Color(0xFF7A0000)];
    case VideoPlatform.tiktok:
      return const [Color(0xFF25F4EE), Color(0xFFFE2C55)];
    case VideoPlatform.instagram:
      return const [Color(0xFFFA7E1E), Color(0xFF962FBF)];
    case null:
      return const [Colors.grey, Colors.black87];
  }
}

/// Thumbnail of a video post (a cheap image - no WebView is created in lists).
class VideoThumb extends StatelessWidget {
  const VideoThumb({
    super.key,
    required this.post,
    this.playSize = 56,
    this.showBadge = true,
  });

  final Post post;
  final double playSize;
  final bool showBadge;

  @override
  Widget build(BuildContext context) {
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: _platformColors(post.videoPlatform),
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(platformIcon(post.videoPlatform),
            color: Colors.white54, size: playSize * 1.4),
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
            child: Icon(Icons.play_arrow_rounded,
                color: Colors.white, size: playSize * 0.7),
          ),
        ),
        if (showBadge && post.videoPlatform != null)
          Positioned(
            top: 10,
            right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(platformIcon(post.videoPlatform),
                      color: Colors.white, size: 14),
                  const SizedBox(width: 4),
                  Text(post.videoPlatform!.label,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
