import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/post.dart';
import 'video_thumb.dart';

/// Photos and clips in their real proportions (no fixed crop). Square corners.
/// Photos from before v1.5 have no stored size: it is read once from the loaded image and remembered.
class PostMedia extends StatefulWidget {
  const PostMedia({
    super.key,
    required this.post,
    this.playSize = 64,
    this.maxHeight,
  });

  final Post post;

  /// Size of the play icon shown on clips.
  final double playSize;

  /// Very tall media is shrunk to this height (and centred) instead of filling the screen.
  final double? maxHeight;

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
  ImageStream? _stream;
  ImageStreamListener? _listener;

  Post get post => widget.post;

  @override
  void initState() {
    super.initState();
    if (post.isVideo) {
      _aspect = post.videoAspect > 0 ? post.videoAspect : 9 / 16;
    } else {
      _aspect = post.imageAspect > 0
          ? post.imageAspect
          : PostMedia._seen[post.imageUrl];
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (post.isVideo || _provider != null) return;
    final mq = MediaQuery.of(context);
    final w = (mq.size.width * mq.devicePixelRatio).clamp(480, 1600).round();
    _provider = CachedNetworkImageProvider(post.imageUrl, maxWidth: w);
    if (_aspect == null) {
      final stream = _provider!.resolve(ImageConfiguration.empty);
      late final ImageStreamListener l;
      l = ImageStreamListener((info, _) {
        final a = info.image.width / info.image.height;
        PostMedia._seen[post.imageUrl] = a;
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
    if (post.isVideo) return VideoThumb(post: post, playSize: widget.playSize);
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
