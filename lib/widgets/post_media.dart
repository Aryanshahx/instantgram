import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/post.dart';
import 'inline_video.dart';
import 'video_thumb.dart';

/// Photos and clips in their real proportions (no fixed crop). Square corners.
/// Photos from before v1.5 have no stored size: it is read once from the loaded image and remembered.
class PostMedia extends StatefulWidget {
  const PostMedia({
    super.key,
    required this.post,
    this.playSize = 64,
    this.maxHeight,
    this.inline = false,
    this.showSound = true,
  });

  final Post post;

  /// Size of the play icon shown on clips.
  final double playSize;

  /// Very tall media is shrunk to this height (and centred) instead of filling the screen.
  final double? maxHeight;

  /// Clips play by themselves while on screen (the Discover feed). Grids leave this off.
  final bool inline;

  /// The speaker button on an inline clip (hidden in small grid tiles).
  final bool showSound;

  /// Keeps the extremes sane (panoramas, very tall screenshots).
  static const double minAspect = 0.5;
  static const double maxAspect = 2.0;

  static final Map<String, double> _seen = {};

  @override
  State<PostMedia> createState() => _PostMediaState();
}

class _PostMediaState extends State<PostMedia> {
  double? _aspect;
  ImageProvider? _provider;
  bool _probed = false;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  Post get post => widget.post;

  @override
  void initState() {
    super.initState();
    if (post.isVideo) {
      // the thumbnail is the real first frame, so its proportions win once they are known
      _aspect =
          PostMedia._seen[post.thumbnailUrl] ??
          (post.videoAspect > 0 ? post.videoAspect : 9 / 16);
    } else {
      _aspect = post.imageAspect > 0
          ? post.imageAspect
          : PostMedia._seen[post.imageUrl];
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_provider != null || _probed) return;
    final String url;
    if (post.isVideo) {
      url = post.thumbnailUrl;
      if (url.isEmpty || PostMedia._seen[url] != null) return;
      _probed = true;
    } else {
      final mq = MediaQuery.of(context);
      final w = (mq.size.width * mq.devicePixelRatio).clamp(480, 1600).round();
      _provider = CachedNetworkImageProvider(post.imageUrl, maxWidth: w);
      url = post.imageUrl;
    }
    if (post.isVideo || _aspect == null) {
      final probe = _provider ?? CachedNetworkImageProvider(url);
      final stream = probe.resolve(ImageConfiguration.empty);
      late final ImageStreamListener l;
      l = ImageStreamListener((info, _) {
        final a = info.image.width / info.image.height;
        PostMedia._seen[url] = a;
        stream.removeListener(l);
        if (mounted) setState(() => _aspect = a);
      }, onError: (_, _) => stream.removeListener(l));
      _stream = stream;
      _listener = l;
      stream.addListener(l);
    }
  }

  @override
  void dispose() {
    final l = _listener;
    if (l != null) _stream?.removeListener(l);
    super.dispose();
  }

  Widget _content(BuildContext context) {
    if (post.isVideo) {
      // the whole frame, never cropped
      return ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            VideoThumb(
              post: post,
              playSize: widget.playSize,
              fit: BoxFit.contain,
              showPlay: !widget.inline,
            ),
            // in the feed the clip plays by itself while it is on screen
            if (widget.inline)
              InlineVideoLayer(post: post, showSound: widget.showSound),
          ],
        ),
      );
    }
    final p = _provider;
    if (p == null) return ColoredBox(color: context.cardHigh);
    return Image(
      image: p,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, sync) =>
          sync || frame != null ? child : ColoredBox(color: context.cardHigh),
      errorBuilder: (context, _, _) => ColoredBox(
        color: context.cardHigh,
        child: Icon(Icons.broken_image_outlined, color: context.muted),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.cardHigh,
      child: LayoutBuilder(
        builder: (context, c) {
          final a = (_aspect ?? 4 / 5).clamp(
            PostMedia.minAspect,
            PostMedia.maxAspect,
          );
          var w = c.maxWidth;
          var h = w / a;
          final cap = widget.maxHeight;
          if (cap != null && h > cap) {
            h = cap;
            w = h * a;
          }
          return Center(
            heightFactor: 1,
            child: SizedBox(width: w, height: h, child: _content(context)),
          );
        },
      ),
    );
  }
}
