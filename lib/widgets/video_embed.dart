import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../models/video_link.dart';

Future<void> openExternally(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Plays a YouTube / TikTok / Instagram video INSIDE the app via the
/// platform's own embed player. The video bytes never touch our servers.
class VideoEmbed extends StatefulWidget {
  const VideoEmbed({
    super.key,
    required this.platform,
    required this.videoId,
    required this.url,
    this.autoPlay = true,
  });

  final VideoPlatform platform;
  final String? videoId;
  final String url;
  final bool autoPlay;

  @override
  State<VideoEmbed> createState() => _VideoEmbedState();
}

class _VideoEmbedState extends State<VideoEmbed> {
  YoutubePlayerController? _yt;
  WebViewController? _web;
  bool _loading = true;
  bool _unsupported = false;

  @override
  void initState() {
    super.initState();
    final id = widget.videoId;

    if (widget.platform == VideoPlatform.youtube && id != null && id.isNotEmpty) {
      _yt = YoutubePlayerController.fromVideoId(
        videoId: id,
        autoPlay: widget.autoPlay,
        params: const YoutubePlayerParams(
          showFullscreenButton: false,
          loop: true,
          strictRelatedVideos: true,
        ),
      );
      return;
    }

    final link = VideoLink(
        platform: widget.platform, url: widget.url, id: id);
    final embed = link.embedUrl;
    if (embed == null) {
      _unsupported = true;
      return;
    }

    final baseDomain =
        widget.platform == VideoPlatform.tiktok ? 'tiktok.com' : 'instagram.com';

    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
        onNavigationRequest: (req) {
          final host = Uri.tryParse(req.url)?.host ?? '';
          if (!req.isMainFrame || host.endsWith(baseDomain)) {
            return NavigationDecision.navigate;
          }
          openExternally(req.url);
          return NavigationDecision.prevent;
        },
      ))
      ..loadRequest(Uri.parse(embed));
  }

  @override
  void dispose() {
    _yt?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_unsupported) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.link_off, color: Colors.white54, size: 40),
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(180, 44)),
              onPressed: () => openExternally(widget.url),
              child: Text('Open in ${widget.platform.label}'),
            ),
          ],
        ),
      );
    }

    if (_yt != null) {
      return LayoutBuilder(
        builder: (context, c) => Center(
          child: YoutubePlayer(
            controller: _yt!,
            aspectRatio: c.maxWidth / c.maxHeight,
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        WebViewWidget(controller: _web!),
        if (_loading)
          const ColoredBox(
            color: Colors.black,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
          ),
      ],
    );
  }
}
