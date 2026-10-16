import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import 'net_image.dart';

/// v0.18 Hyper Intelligence: blurred cover of sensitive content.
/// "Sensitive content · Tap to view". [compact] = only an eye icon
/// (grid tiles; tapping the tile opens the post, where you can reveal it).
class HiBlur extends StatelessWidget {
  const HiBlur({
    super.key,
    this.imageUrl = '',
    this.onReveal,
    this.compact = false,
  });

  /// Picture under the blur ('' = dark background).
  final String imageUrl;
  final VoidCallback? onReveal;
  final bool compact;

  static const String title = 'Sensitive content';
  static const String reveal = 'Tap to view';
  static const String why =
      'Hyper Intelligence blurred this because it may be upsetting.';

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (imageUrl.isNotEmpty)
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
              child: NetImage(imageUrl, fit: BoxFit.cover),
            )
          else
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF2B2F3A), Color(0xFF14161C)],
                ),
              ),
            ),
          ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
          if (compact)
            const Center(
              child: Icon(
                Icons.visibility_off_outlined,
                key: ValueKey('hi-tile'),
                size: 26,
                color: Colors.white,
              ),
            )
          else
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.visibility_off_outlined,
                      size: 34,
                      color: Colors.white,
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      why,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12.5, color: Colors.white70),
                    ),
                    if (onReveal != null) ...[
                      const SizedBox(height: 14),
                      OutlinedButton(
                        key: const ValueKey('hi-reveal'),
                        onPressed: onReveal,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white54),
                          visualDensity: VisualDensity.compact,
                        ),
                        child: const Text(reveal),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Small label on your OWN post while Hyper Intelligence / the admin
/// look at it (others see it blurred or not at all).
class HiOwnerPill extends StatelessWidget {
  const HiOwnerPill({super.key, required this.hidden});
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('hi-owner-pill'),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hidden ? Icons.visibility_off_outlined : Icons.blur_on,
            size: 14,
            color: AppColors.lime,
          ),
          const SizedBox(width: 5),
          Text(
            hidden ? 'Hidden · under review' : 'Blurred for others',
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
