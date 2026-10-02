import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';

class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.url,
    this.radius = 20,
    this.ring = false,
    this.seen = false,
  });

  final String url;
  final double radius;

  /// Draw the Instagram-style gradient ring (active story).
  final bool ring;
  final bool seen;

  @override
  Widget build(BuildContext context) {
    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: context.softFill,
      backgroundImage: url.isEmpty ? null : CachedNetworkImageProvider(url),
      child: url.isEmpty
          ? Icon(Icons.person, size: radius * 1.2, color: context.muted)
          : null,
    );
    if (!ring) return avatar;

    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: seen ? null : AppTheme.instaGradient,
        color: seen ? context.hairline : null,
      ),
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Theme.of(context).scaffoldBackgroundColor,
        ),
        child: avatar,
      ),
    );
  }
}
