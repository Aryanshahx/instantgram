import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/location_service.dart';

/// A small map (OpenStreetMap tiles) with a pin, and the coordinates underneath.
class LocationCard extends StatelessWidget {
  const LocationCard({
    super.key,
    required this.lat,
    required this.lng,
    this.width = 240,
    this.height = 150,
    this.onTap,
    this.textColor,
  });

  final double lat;
  final double lng;
  final double width;
  final double height;
  final VoidCallback? onTap;
  final Color? textColor;

  static const int zoom = 16;
  static const double tile = 256;

  @override
  Widget build(BuildContext context) {
    final spot = mapSpot(lat, lng, zoom);
    // 2 x 2 tiles around the point; the point is moved to the centre of the card
    final x0 = (spot.x - 0.5).floor();
    final y0 = (spot.y - 0.5).floor();
    final left = width / 2 - (spot.x - x0) * tile;
    final top = height / 2 - (spot.y - y0) * tile;
    final fg = textColor ?? Theme.of(context).colorScheme.onSurface;
    return GestureDetector(
      key: const ValueKey('locationCard'),
      onTap: onTap,
      child: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: width,
                height: height,
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    const Positioned.fill(
                      child: ColoredBox(color: Color(0xFFE8ECE4)),
                    ),
                    for (var dx = 0; dx < 2; dx++)
                      for (var dy = 0; dy < 2; dy++)
                        Positioned(
                          left: left + dx * tile,
                          top: top + dy * tile,
                          width: tile,
                          height: tile,
                          child: CachedNetworkImage(
                            imageUrl:
                                'https://tile.openstreetmap.org/$zoom/${x0 + dx}/${y0 + dy}.png',
                            fit: BoxFit.fill,
                            httpHeaders: const {
                              'User-Agent': 'InstantGram/1.10 (Android)',
                            },
                            errorWidget: (_, _, _) => const SizedBox.shrink(),
                            fadeInDuration: const Duration(milliseconds: 120),
                          ),
                        ),
                    Center(
                      child: Transform.translate(
                        offset: const Offset(0, -16),
                        child: const Icon(
                          Icons.location_on_rounded,
                          size: 38,
                          color: AppTheme.coral,
                          shadows: [
                            Shadow(blurRadius: 6, color: Colors.black38),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.near_me_rounded, size: 14, color: fg),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    formatCoords(lat, lng),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
