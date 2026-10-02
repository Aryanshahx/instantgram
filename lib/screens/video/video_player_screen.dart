import 'package:flutter/material.dart';

import '../../models/post.dart';
import '../../models/video_link.dart';
import '../../widgets/video_embed.dart';

class VideoPlayerScreen extends StatelessWidget {
  const VideoPlayerScreen({super.key, required this.post});
  final Post post;

  @override
  Widget build(BuildContext context) {
    final platform = post.videoPlatform ?? VideoPlatform.youtube;
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: Text('@${post.authorUsername}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: VideoEmbed(
                  platform: platform,
                  videoId: post.videoId,
                  url: post.videoUrl,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(44),
                  ),
                  onPressed: () => openExternally(post.videoUrl),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text('Open in ${platform.label}'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
