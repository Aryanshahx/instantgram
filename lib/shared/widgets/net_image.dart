import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Cached network image with dark placeholder + error fallback.
class NetImage extends StatelessWidget {
  const NetImage(this.url, {super.key, this.fit = BoxFit.cover});

  final String url;
  final BoxFit fit;

  /// Set to true in widget tests (no disk cache available there).
  static bool disableCache = false;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return const _Fallback();
    if (disableCache) {
      return Image.network(
        url,
        fit: fit,
        errorBuilder: (context, error, stack) => const _Fallback(),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: fit,
      fadeInDuration: const Duration(milliseconds: 200),
      placeholder: (context, url) => Container(color: AppColors.surface),
      errorWidget: (context, url, error) => const _Fallback(),
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      alignment: Alignment.center,
      child: const Icon(Icons.image_outlined, color: AppColors.textHint),
    );
  }
}
