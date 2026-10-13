import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../features/stories/data/moments_index.dart';
import 'net_image.dart';

/// Circular avatar with optional lime "+" badge and moment ring.
///
/// Pass [uid] to show the glowing ring automatically when that user has
/// an active moment; tapping the avatar then opens the moment.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.url,
    this.size = 44,
    this.name = '',
    this.showPlus = false,
    this.ring = false,
    this.seen = false,
    this.onPlusTap,
    this.uid,
    this.openMoment = true,
  });

  final String url;
  final double size;
  final String name;
  final bool showPlus;

  /// Always draw a ring (outside [size]).
  final bool ring;

  /// Ring drawn grey (already watched).
  final bool seen;
  final VoidCallback? onPlusTap;

  /// Owner of the avatar (enables the automatic moment ring).
  final String? uid;

  /// Tap opens the moment when the ring is shown.
  final bool openMoment;

  @override
  Widget build(BuildContext context) {
    final id = uid;
    if (id == null || id.isEmpty) {
      return _build(context, ring: ring, seen: seen, inside: false);
    }
    final index = MomentsIndex.instance;
    return ListenableBuilder(
      listenable: index.listenable,
      builder: (context, _) {
        final g = index.of(id);
        if (g == null) {
          return _build(context, ring: ring, seen: seen, inside: false);
        }
        final child = _build(
          context,
          ring: true,
          seen: index.allSeen(g),
          inside: !ring,
        );
        if (!openMoment) return child;
        return GestureDetector(
          onTap: () => index.open(context, id),
          child: child,
        );
      },
    );
  }

  /// [inside] = keep the total size == [size] (ring drawn inside it).
  Widget _build(
    BuildContext context, {
    required bool ring,
    required bool seen,
    required bool inside,
  }) {
    final ringW = (size * 0.055).clamp(1.8, 3.2);
    final gap = (size * 0.045).clamp(1.5, 2.8);
    final inner = inside ? size - 2 * (ringW + gap) : size;

    Widget circle = ClipOval(
      child: SizedBox(
        width: inner,
        height: inner,
        child: url.isEmpty ? _Initials(name: name, size: inner) : NetImage(url),
      ),
    );

    if (ring) {
      circle = MomentRing(seen: seen, width: ringW, gap: gap, child: circle);
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

/// Faded lime → mint ring for moments you already watched (v0.7:
/// the ring stays, just softer).
const double kSeenRingOpacity = 0.4;
final LinearGradient kSeenRingGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [
    AppColors.lime.withValues(alpha: kSeenRingOpacity),
    AppColors.mint.withValues(alpha: kSeenRingOpacity),
  ],
);

/// Lime → mint moment ring (faded when [seen]).
class MomentRing extends StatelessWidget {
  const MomentRing({
    super.key,
    required this.child,
    this.seen = false,
    this.width = 3,
    this.gap = 2.5,
  });

  final Widget child;
  final bool seen;
  final double width;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(width),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // seen moments keep a faded green ring (no glow anywhere)
        gradient: seen ? kSeenRingGradient : AppColors.fabGradient,
      ),
      child: Container(
        padding: EdgeInsets.all(gap),
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.background,
        ),
        child: child,
      ),
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
