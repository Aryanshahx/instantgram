import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/media_url.dart';
import '../core/theme.dart';

/// Squircle avatar (rounded square) with an optional lime "moment" ring.
/// Falls back to a gradient tile with the user's initial.
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
    final corner = size * 0.34;

    Widget initial() => Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(gradient: AppTheme.auroraGradient),
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.w900,
          color: AppTheme.ink,
        ),
      ),
    );

    final inner = ClipRRect(
      borderRadius: BorderRadius.circular(corner),
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
        borderRadius: BorderRadius.circular(corner + 5),
        gradient: seen ? null : AppTheme.voltGradient,
        color: seen ? context.hairline : null,
      ),
      child: Container(
        padding: const EdgeInsets.all(2.5),
        decoration: BoxDecoration(
          color: context.bg,
          borderRadius: BorderRadius.circular(corner + 2.5),
        ),
        child: inner,
      ),
    );
  }
}
