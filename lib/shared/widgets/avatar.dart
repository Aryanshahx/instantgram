import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import 'net_image.dart';

/// Circular avatar with optional lime "+" badge and story ring.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.url,
    this.size = 44,
    this.name = '',
    this.showPlus = false,
    this.ring = false,
    this.onPlusTap,
  });

  final String url;
  final double size;
  final String name;
  final bool showPlus;
  final bool ring;
  final VoidCallback? onPlusTap;

  @override
  Widget build(BuildContext context) {
    Widget circle = ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: url.isEmpty ? _Initials(name: name, size: size) : NetImage(url),
      ),
    );

    if (ring) {
      circle = Container(
        padding: const EdgeInsets.all(3),
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: AppColors.fabGradient,
        ),
        child: Container(
          padding: const EdgeInsets.all(2.5),
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.background,
          ),
          child: circle,
        ),
      );
    }

    if (!showPlus) return circle;

    final badge = size * 0.32;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        circle,
        Positioned(
          right: -2,
          bottom: -2,
          child: GestureDetector(
            onTap: onPlusTap,
            child: Container(
              width: badge,
              height: badge,
              decoration: BoxDecoration(
                color: AppColors.lime,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.background, width: 3),
              ),
              child: Icon(Icons.add, size: badge * 0.62, color: Colors.black),
            ),
          ),
        ),
      ],
    );
  }
}

class _Initials extends StatelessWidget {
  const _Initials({required this.name, required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final letter = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Container(
      color: AppColors.surfaceHigh,
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          fontSize: size * 0.4,
          fontWeight: FontWeight.w700,
          color: AppColors.lime,
        ),
      ),
    );
  }
}
