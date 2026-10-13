import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
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
    paintTextLayer(canvas, t, fw, fh, textScale: spec.textScale);
  }

  final picture = rec.endRecording();
  try {
    return await picture.toImage(outW, outH);
  } finally {
    picture.dispose();
  }
}

/// Same look as the editor's text widget.
void paintTextLayer(
  Canvas canvas,
  TextLayer t,
  double fw,
  double fh, {
  double textScale = 1,
}) {
  final fs = (t.size * fw).clamp(10.0, 120.0) * textScale;
  final padH = t.background ? fs * 0.4 : 0.0;
  final padV = t.background ? fs * 0.15 : 0.0;
  final tp = TextPainter(
    text: TextSpan(
      text: t.text,
      style: TextStyle(
        fontFamily: AppTheme.fontFamily,
        color: t.color,
        fontSize: fs,
        fontWeight: FontWeight.w800,
        height: 1.15,
        shadows: t.background
            ? null
            : const [Shadow(blurRadius: 6, color: Colors.black54)],
      ),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: math.max(1, fw * 0.9 - padH * 2));
  final boxW = tp.width + padH * 2;
  final boxH = tp.height + padV * 2;
  final left = t.pos.dx * fw - boxW / 2;
  final top = t.pos.dy * fh - boxH / 2;
  if (t.background) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, boxW, boxH),
        Radius.circular(fs * 0.3),
      ),
      Paint()
        ..color = t.color.computeLuminance() > 0.5
            ? Colors.black87
            : Colors.white,
    );
  }
  tp.paint(canvas, Offset(left + padH, top + padV));
  tp.dispose();
}
