import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../shared/widgets/styled_text.dart';
import 'edit_models.dart';

/// Size of the crop frame and of the photo box inside it, exactly like the
/// editor lays them out.
class PhotoLayout {
  const PhotoLayout(this.frame, this.photo);

  /// Crop frame (what gets saved).
  final Size frame;

  /// Photo box (rotated photo, covers the frame at zoom 1).
  final Size photo;

  /// [natural] = photo pixels, [aspect] = frame shape (w / h),
  /// [box] = space available on screen.
  static PhotoLayout compute({
    required Size natural,
    required int turns,
    required double aspect,
    required Size box,
  }) {
    final nw = natural.width <= 0 ? 1.0 : natural.width;
    final nh = natural.height <= 0 ? 1.0 : natural.height;
    final na = turns.isOdd ? nh / nw : nw / nh;
    final a = aspect.isFinite && aspect > 0 ? aspect : na;
    final maxW = box.width <= 0 ? 1.0 : box.width;
    final maxH = box.height <= 0 ? 1.0 : box.height;
    double fw, fh;
    if (maxW / maxH > a) {
      fh = maxH;
      fw = maxH * a;
    } else {
      fw = maxW;
      fh = maxW / a;
    }
    double cw, ch;
    if (na > a) {
      ch = fh;
      cw = fh * na;
    } else {
      cw = fw;
      ch = fw / na;
    }
    return PhotoLayout(Size(fw, fh), Size(cw, ch));
  }

  /// Zoom matrix that centers the photo in the frame.
  Matrix4 centered() => Matrix4.translationValues(
    -(photo.width - frame.width) / 2,
    -(photo.height - frame.height) / 2,
    0,
  );
}

/// Everything needed to draw an edited photo.
class PhotoRenderSpec {
  const PhotoRenderSpec({
    required this.layout,
    required this.transform,
    this.turns = 0,
    this.flip = false,
    this.colorMatrix,
    this.texts = const [],
    this.textScale = 1,
    this.stickers = const {},
  });

  final PhotoLayout layout;

  /// Zoom / move of the photo inside the frame (editor's InteractiveViewer).
  final Matrix4 transform;
  final int turns;
  final bool flip;
  final List<double>? colorMatrix;
  final List<TextLayer> texts;

  /// App text size (Settings → Accessibility), so text matches the editor.
  final double textScale;

  /// v0.13: loaded sticker pictures (`stk:ID` -> image).
  final Map<String, ui.Image> stickers;
}

/// Draws the edited photo at [outWidth] pixels wide (height follows the
/// frame shape). Black where the photo does not cover the frame.
Future<ui.Image> renderPhoto(
  ui.Image src,
  PhotoRenderSpec spec, {
  required int outWidth,
}) async {
  final fw = spec.layout.frame.width;
  final fh = spec.layout.frame.height;
  final pw = spec.layout.photo.width;
  final ph = spec.layout.photo.height;
  final outW = outWidth < 1 ? 1 : outWidth;
  final outH = math.max(1, (outW * fh / fw).round());
  final k = outW / fw;

  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.scale(k);
  canvas.clipRect(Rect.fromLTWH(0, 0, fw, fh));
  canvas.drawRect(Rect.fromLTWH(0, 0, fw, fh), Paint()..color = Colors.black);

  // photo: zoom/move -> center -> flip -> rotate (same order as the widgets)
  canvas.save();
  canvas.transform(spec.transform.storage);
  canvas.translate(pw / 2, ph / 2);
  if (spec.flip) canvas.scale(-1, 1);
  final q = spec.turns % 4;
  if (q != 0) canvas.rotate(q * math.pi / 2);
  final odd = q.isOdd;
  final dw = odd ? ph : pw;
  final dh = odd ? pw : ph;
  final paint = Paint()
    ..filterQuality = FilterQuality.high
    ..isAntiAlias = true;
  final m = spec.colorMatrix;
  if (m != null && m.length == 20) paint.colorFilter = ColorFilter.matrix(m);
  canvas.drawImageRect(
    src,
    Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    Rect.fromCenter(center: Offset.zero, width: dw, height: dh),
    paint,
  );
  canvas.restore();

  for (final t in spec.texts) {
    final img = spec.stickers[t.text];
    if (img != null) {
      paintSticker(canvas, img, t, fw, fh);
    } else {
      paintTextLayer(canvas, t, fw, fh, textScale: spec.textScale);
    }
  }

  final picture = rec.endRecording();
  try {
    return await picture.toImage(outW, outH);
  } finally {
    picture.dispose();
  }
}

/// v0.13: a pack sticker ([TextLayer.size] = width part of the frame).
void paintSticker(
  Canvas canvas,
  ui.Image img,
  TextLayer t,
  double fw,
  double fh,
) {
  final w = t.size * fw;
  final h = w * img.height / math.max(1, img.width);
  final at = Offset(t.pos.dx * fw, t.pos.dy * fh);
  final turned = t.rotation != 0;
  if (turned) {
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(t.rotation);
  }
  canvas.drawImageRect(
    img,
    Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
    Rect.fromCenter(center: turned ? Offset.zero : at, width: w, height: h),
    Paint()
      ..filterQuality = FilterQuality.high
      ..isAntiAlias = true,
  );
  if (turned) canvas.restore();
}

/// Same look as the editor's text widget.
void paintTextLayer(
  Canvas canvas,
  TextLayer t,
  double fw,
  double fh, {
  double textScale = 1,
}) {
  // v0.12: limits as a part of the width (same on screen and in the file)
  final fs = (t.size * fw).clamp(fw * 0.02, fw * 0.5) * textScale;
  final l = StyledTextLayout(t.spec, fontSize: fs, maxWidth: fw * 0.9);
  l.paintAt(canvas, Offset(t.pos.dx * fw, t.pos.dy * fh), rotation: t.rotation);
  l.dispose();
}
