import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../shared/models/post.dart';
import '../../shared/widgets/media_links.dart';
import '../../shared/widgets/stickers.dart';
import '../../shared/widgets/styled_text.dart';
import '../../shared/widgets/video_extras.dart';
import 'bake_filter.dart';
import 'filters.dart';

/// v0.0.2: what a video looks like at one moment: the frame with the
/// filter AND the texts / stickers shown at that moment (same as the
/// player). Used on the share screen, the cover picker and for the cover
/// picture.

/// Texts / stickers visible at [ms] (position in the video file).
List<VideoOverlay> overlaysAt(List<VideoOverlay> all, int ms) => [
  for (final o in all)
    if (o.visibleAt(ms)) o,
];

/// Texts / stickers of a video at [ms], on top of a frame shown in a box
/// with the video's shape. Never takes taps.
class StillOverlays extends StatelessWidget {
  const StillOverlays({super.key, required this.overlays, required this.ms});

  final List<VideoOverlay> overlays;
  final int ms;

  @override
  Widget build(BuildContext context) {
    final shown = overlaysAt(overlays, ms);
    if (shown.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, box) => Stack(
          clipBehavior: Clip.none,
          children: [
            for (final o in shown)
              OverlayPlace(
                x: o.x,
                y: o.y,
                width: box.maxWidth,
                height: box.maxHeight,
                child: OverlayView(overlay: o, frameWidth: box.maxWidth),
              ),
          ],
        ),
      ),
    );
  }
}

/// A video frame exactly as it will look: real shape, filter, texts,
/// stickers and link stickers. [frame] = picture of the frame at [ms].
class EditedFrame extends StatelessWidget {
  const EditedFrame({
    super.key,
    required this.frame,
    required this.edits,
    required this.aspect,
    required this.ms,
    this.links = const [],
  });

  /// Image of the frame (null = still loading).
  final ImageProvider? frame;
  final VideoEdits edits;
  final double aspect;
  final int ms;
  final List<MediaLink> links;

  @override
  Widget build(BuildContext context) {
    final f = frame;
    return AspectRatio(
      aspectRatio: safeAspect(aspect),
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.black),
            if (f != null)
              applyMatrix(
                edits.filter,
                Image(image: f, fit: BoxFit.cover, gaplessPlayback: true),
              ),
            StillOverlays(overlays: edits.overlays, ms: ms),
            if (links.isNotEmpty)
              IgnorePointer(
                child: MediaLinksLayer(links: links, aspect: aspect),
              ),
          ],
        ),
      ),
    );
  }
}

/// Paints one text / sticker like [OverlayView] on a [fw] x [fh] frame.
void paintVideoOverlay(
  Canvas canvas,
  VideoOverlay o,
  double fw,
  double fh, {
  Map<String, ui.Image> stickers = const {},
}) {
  final center = Offset(o.x * fw, o.y * fh);
  final pic = o.isSticker ? stickers[o.text] : null;
  if (pic != null) {
    final w = o.size * fw;
    final h = w * pic.height / math.max(1, pic.width);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(o.rotation);
    canvas.drawImageRect(
      pic,
      Rect.fromLTWH(0, 0, pic.width.toDouble(), pic.height.toDouble()),
      Rect.fromCenter(center: Offset.zero, width: w, height: h),
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );
    canvas.restore();
    return;
  }
  if (o.isSticker && StickerPack.isPack(o.text)) return; // picture missing
  final fs = (o.size * fw).clamp(6.0, 2000.0);
  final l = StyledTextLayout(
    TextSpec.ofOverlay(o),
    fontSize: fs,
    maxWidth: o.isSticker ? fw * 4 : fw * 0.9,
  );
  l.paintAt(canvas, center, rotation: o.rotation);
  l.dispose();
}

class _Rgba {
  const _Rgba(this.data, this.width, this.height);
  final Uint8List data;
  final int width;
  final int height;
}

Uint8List _jpg(_Rgba r) {
  final im = img.Image.fromBytes(
    width: r.width,
    height: r.height,
    bytes: r.data.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return img.encodeJpg(im, quality: 88);
}

/// Output size of a cover: [maxWidth] wide (or less), the video's shape.
@visibleForTesting
Size coverSize(int frameWidth, double aspect, {int maxWidth = 1080}) {
  final w = math.max(1, math.min(maxWidth, frameWidth));
  final h = math.max(1, (w / safeAspect(aspect)).round());
  return Size(w.toDouble(), h.toDouble());
}

/// v0.0.2: cover / thumbnail picture of a video at [ms]: the frame with
/// the filter and the texts / stickers shown then. Falls back to the
/// filter only (old way) if drawing fails.
Future<File> bakeCover(
  File frame,
  VideoEdits edits, {
  required int ms,
  required double aspect,
}) async {
  final shown = overlaysAt(edits.overlays, ms);
  if (shown.isEmpty) return bakeFilter(frame, edits.filter);
  ui.Image? src;
  final stickers = <String, ui.Image>{};
  try {
    final codec = await ui.instantiateImageCodec(await frame.readAsBytes());
    src = (await codec.getNextFrame()).image;
    codec.dispose();
    for (final o in shown) {
      if (o.isSticker &&
          StickerPack.isPack(o.text) &&
          !stickers.containsKey(o.text)) {
        final s = await StickerPack.load(o.text);
        if (s != null) stickers[o.text] = s;
      }
    }
    final size = coverSize(src.width, aspect);
    final fw = size.width, fh = size.height;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final paint = Paint()..filterQuality = FilterQuality.high;
    final m = edits.filter;
    if (m != null && m.length == 20 && !ColorMatrix.isIdentity(m)) {
      paint.colorFilter = ColorFilter.matrix(m);
    }
    // the frame fills the video shape (like BoxFit.cover)
    final s = applyBoxFit(
      BoxFit.cover,
      Size(src.width.toDouble(), src.height.toDouble()),
      size,
    );
    final srcRect = Alignment.center.inscribe(
      s.source,
      Offset.zero & Size(src.width.toDouble(), src.height.toDouble()),
    );
    canvas.drawImageRect(src, srcRect, Offset.zero & size, paint);
    for (final o in shown) {
      paintVideoOverlay(canvas, o, fw, fh, stickers: stickers);
    }
    final picture = rec.endRecording();
    final out = await picture.toImage(fw.round(), fh.round());
    picture.dispose();
    final data = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
    final w = out.width, h = out.height;
    out.dispose();
    if (data == null) throw StateError('no pixels');
    final bytes = await compute(_jpg, _Rgba(data.buffer.asUint8List(), w, h));
    final dir = await Directory.systemTemp.createTemp('ig_cover');
    final f = File(
      '${dir.path}/cover_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await f.writeAsBytes(bytes, flush: true);
    return f;
  } catch (e) {
    debugPrint('cover: $e');
    return bakeFilter(frame, edits.filter);
  } finally {
    src?.dispose();
    for (final s in stickers.values) {
      s.dispose();
    }
  }
}
