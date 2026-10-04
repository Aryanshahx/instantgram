import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/media_url.dart';
import '../core/theme.dart';

/// Round profile picture with an optional lime "moment" ring.
/// Without a photo it shows a default silhouette picture.
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.url,
    this.name = '',
    this.radius = 20,
    this.ring = false,
    this.seen = false,
  });

  final String url;
  final String name;
  final double radius;
  final bool ring;
  final bool seen;

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;

    // The default picture: a soft person silhouette (never a letter).
    Widget initial() => SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: const BoxDecoration(gradient: AppTheme.auroraGradient),
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            Positioned(
              top: size * 0.2,
              child: Container(
                width: size * 0.34,
                height: size * 0.34,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.92),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Positioned(
              bottom: -size * 0.28,
              child: Container(
                width: size * 0.78,
                height: size * 0.66,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.all(
                    Radius.elliptical(size * 0.39, size * 0.33),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final inner = ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: resolveMediaUrl(url).isEmpty
            ? initial()
            : CachedNetworkImage(
                imageUrl: resolveMediaUrl(url),
                fit: BoxFit.cover,
                placeholder: (_, _) => ColoredBox(color: context.cardHigh),
                errorWidget: (_, _, _) => initial(),
              ),
      ),
    );

    if (!ring) return inner;

    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: seen ? null : AppTheme.voltGradient,
        color: seen ? context.hairline : null,
      ),
      child: Container(
        padding: const EdgeInsets.all(2.5),
        decoration: BoxDecoration(color: context.bg, shape: BoxShape.circle),
        child: inner,
      ),
    );
  }
}
