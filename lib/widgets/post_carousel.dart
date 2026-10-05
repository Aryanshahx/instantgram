import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/post.dart';
import 'inline_video.dart';

/// Photos and videos of one post, swiped sideways (like a carousel on Instagram): dots under
/// the pictures and a "2/5" counter. A video starts by itself while its page is showing; the
/// post's music keeps playing across pages. [inline] = false only shows the cover pictures.
class PostCarousel extends StatefulWidget {
  const PostCarousel({
    super.key,
    required this.post,
    this.inline = true,
    this.showSound = true,
  });

  final Post post;
  final bool inline;
  final bool showSound;

  @override
  State<PostCarousel> createState() => _PostCarouselState();
}

class _PostCarouselState extends State<PostCarousel> {
  final PageController _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Widget _page0(BuildContext context, PostItem it) {
    final url = it.thumbUrl;
    return ColoredBox(
      color: Colors.black,
      child: url.isEmpty
          ? Icon(Icons.movie_rounded, color: Colors.white24, size: 64)
          : CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.contain,
              placeholder: (_, _) => ColoredBox(color: context.cardHigh),
              errorWidget: (_, _, _) =>
                  Icon(Icons.broken_image_outlined, color: context.muted),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.post.items;
    final cur = items[_page.clamp(0, items.length - 1)];
    return Stack(
      fit: StackFit.expand,
      children: [
        PageView.builder(
          key: const ValueKey('carousel'),
          controller: _pages,
          itemCount: items.length,
          onPageChanged: (i) => setState(() => _page = i),
          itemBuilder: (context, i) {
            final it = items[i];
            return Stack(
              fit: StackFit.expand,
              children: [
                _page0(context, it),
                if (it.video && !(widget.inline && i == _page))
                  const Center(
                    child: Icon(
                      Icons.play_arrow_rounded,
                      size: 56,
                      color: Colors.white,
                      shadows: [Shadow(blurRadius: 12, color: Colors.black54)],
                    ),
                  ),
              ],
            );
          },
        ),
        // plays the current page's video, and the post's music
        if (widget.inline && (cur.video || widget.post.hasMusic))
          _Layer(
            post: widget.post,
            url: cur.video ? cur.url : '',
            showSound: widget.showSound,
          ),
        Positioned(
          right: 10,
          top: 10,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${_page + 1}/${items.length}',
                key: const ValueKey('carouselCount'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 8,
          child: IgnorePointer(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < items.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.symmetric(horizontal: 2.5),
                    width: i == _page ? 7 : 5.5,
                    height: i == _page ? 7 : 5.5,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _page ? AppTheme.volt : Colors.white70,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Keeps one [InlineVideoLayer] alive while the page (and so the video) changes.
class _Layer extends StatelessWidget {
  const _Layer({
    required this.post,
    required this.url,
    required this.showSound,
  });
  final Post post;
  final String url;
  final bool showSound;

  @override
  Widget build(BuildContext context) => InlineVideoLayer(
    key: ValueKey('layer_${post.id}'),
    post: post,
    videoUrl: url,
    showSound: showSound,
  );
}
