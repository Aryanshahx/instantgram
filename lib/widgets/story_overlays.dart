import 'package:flutter/material.dart';

import '../models/story.dart';

/// The 9:16 picture of a moment: the media, with the texts and stickers on top.
/// The composer and the viewer both use it, so what you place is what people see.
class StoryCanvas extends StatelessWidget {
  const StoryCanvas({
    super.key,
    required this.media,
    this.overlays = const [],
    this.overlayBuilder,
    this.onSize,
  });

  final Widget media;
  final List<StoryOverlay> overlays;

  /// Lets the composer wrap each item (to drag it). Null = plain display.
  final Widget Function(int index, Widget chip)? overlayBuilder;

  /// Reports the pixel size of the picture (used for dragging).
  final void Function(Size size)? onSize;

  static const double ratio = 9 / 16;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AspectRatio(
        aspectRatio: ratio,
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            final h = box.maxHeight;
            onSize?.call(Size(w, h));
            return ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(child: media),
                  for (var i = 0; i < overlays.length; i++)
                    Positioned(
                      key: ValueKey('overlay$i'),
                      left: overlays[i].dx * w,
                      top: overlays[i].dy * h,
                      child: FractionalTranslation(
                        translation: const Offset(-0.5, -0.5),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: w * 0.92),
                          child: () {
                            final chip = StoryOverlayChip(
                              overlay: overlays[i],
                              canvasWidth: w,
                            );
                            return overlayBuilder == null
                                ? IgnorePointer(child: chip)
                                : overlayBuilder!(i, chip);
                          }(),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// One text or sticker.
class StoryOverlayChip extends StatelessWidget {
  const StoryOverlayChip({
    super.key,
    required this.overlay,
    required this.canvasWidth,
  });

  final StoryOverlay overlay;
  final double canvasWidth;

  @override
  Widget build(BuildContext context) {
    final size = overlay.fontSize(canvasWidth);
    if (overlay.isImage) {
      // a picture sticker (animated while it is shown on top of a video or in a moment)
      return SizedBox(
        key: const ValueKey('imageSticker'),
        width: size,
        height: size / overlay.aspect,
        child: Image.network(
          overlay.image,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      );
    }
    if (overlay.emoji) {
      return Text(overlay.text, style: TextStyle(fontSize: size, height: 1.1));
    }
    final color = overlay.textColor;
    final onPill = overlay.pill;
    // text on a pill: the pill takes the text colour and the text turns dark or white
    final pillText = color.computeLuminance() > 0.5
        ? const Color(0xFF0B0D12)
        : Colors.white;
    return Container(
      padding: onPill
          ? EdgeInsets.symmetric(horizontal: size * 0.5, vertical: size * 0.22)
          : EdgeInsets.zero,
      decoration: onPill
          ? BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(size * 0.6),
            )
          : null,
      child: Text(
        overlay.text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: onPill ? pillText : color,
          fontSize: size,
          fontWeight: FontWeight.w800,
          height: 1.15,
          shadows: onPill
              ? null
              : const [Shadow(blurRadius: 10, color: Colors.black54)],
        ),
      ),
    );
  }
}
