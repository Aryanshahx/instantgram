import 'package:flutter/material.dart';

import '../../models/post.dart';
import '../../widgets/glass.dart';
import '../../widgets/reel_video.dart';

/// Full-screen player opened from a feed card or a profile tile.
class VideoPlayerScreen extends StatelessWidget {
  const VideoPlayerScreen({super.key, required this.post});
  final Post post;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ReelVideo(post: post, play: true, progressBottom: 18),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  GlassIconButton(
                    icon: Icons.arrow_back_rounded,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '@${post.authorUsername}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (post.caption.isNotEmpty)
            Positioned(
              left: 16,
              right: 16,
              bottom: 40,
              child: IgnorePointer(
                child: Text(
                  post.caption,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    height: 1.3,
                    shadows: [Shadow(blurRadius: 6, color: Colors.black87)],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
