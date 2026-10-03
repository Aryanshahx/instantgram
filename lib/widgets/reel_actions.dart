import 'package:flutter/material.dart';

/// Soft shadow that keeps white icons and text readable on any video.
const List<Shadow> kReelShadow = [Shadow(blurRadius: 8, color: Colors.black54)];

/// A plain icon (no background) used on the Clips screen: back, sound and the action rail.
class ReelIconButton extends StatelessWidget {
  const ReelIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.label,
    this.color = Colors.white,
    this.size = 32,
    this.pop = false,
  });

  final IconData icon;
  final VoidCallback onTap;

  /// Small number or word under the icon.
  final String? label;
  final Color color;
  final double size;

  /// Makes the icon a little bigger (used for the liked heart).
  final bool pop;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 60,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 46,
              child: Center(
                child: AnimatedScale(
                  scale: pop ? 1.2 : 1,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutBack,
                  child: Icon(
                    icon,
                    size: size,
                    color: color,
                    shadows: kReelShadow,
                  ),
                ),
              ),
            ),
            if (label != null)
              Text(
                label!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  shadows: kReelShadow,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
