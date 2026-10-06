import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show consolidateHttpClientResponseBytes;
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

import '../models/story.dart';
import 'photo_edit.dart';

/// Draws texts and stickers on a canvas the way [StoryOverlayChip] shows them on screen
/// (same relative position, size, box and shadow).
void paintOverlays(
  Canvas canvas,
  Size size,
  List<StoryOverlay> overlays, {
  Map<String, ui.Image> images = const {},
}) {
  for (final o in overlays) {
    final fs = o.fontSize(size.width);
    final maxW = size.width * 0.92;
    if (o.isImage) {
      final pic = images[o.still.isNotEmpty ? o.still : o.image];
      if (pic != null) {
        final w = fs;
        final h = fs * pic.height / pic.width;
        canvas.drawImageRect(
          pic,
          Rect.fromLTWH(0, 0, pic.width.toDouble(), pic.height.toDouble()),
          Rect.fromLTWH(
            o.dx * size.width - w / 2,
            o.dy * size.height - h / 2,
            w,
            h,
          ),
          Paint()..filterQuality = FilterQuality.high,
        );
      }
      continue;
    }
    if (o.emoji) {
      final tp = TextPainter(
        text: TextSpan(text: o.text, style: TextStyle(fontSize: fs, height: 1.1)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxW);
      tp.paint(
        canvas,
        Offset(o.dx * size.width - tp.width / 2, o.dy * size.height - tp.height / 2),
      );
      continue;
    }
    final color = o.textColor;
    final pillText = color.computeLuminance() > 0.5
        ? const Color(0xFF0B0D12)
        : const Color(0xFFFFFFFF);
    final padX = o.pill ? fs * 0.5 : 0.0;
    final padY = o.pill ? fs * 0.22 : 0.0;
    final tp = TextPainter(
      text: TextSpan(
        text: o.text,
        style: TextStyle(
          color: o.pill ? pillText : color,
          fontSize: fs,
          fontWeight: FontWeight.w800,
          height: 1.15,
          shadows: o.pill
              ? null
              : const [Shadow(blurRadius: 10, color: Color(0x8A000000))],
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxW - padX * 2);
    final w = tp.width + padX * 2;
    final h = tp.height + padY * 2;
    final left = o.dx * size.width - w / 2;
    final top = o.dy * size.height - h / 2;
    if (o.pill) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, w, h),
          Radius.circular(fs * 0.6),
        ),
        Paint()..color = color,
      );
    }
    tp.paint(canvas, Offset(left + padX, top + padY));
  }
}

Uint8List _encode((Uint8List, int, int) a) {
  final im = img.Image.fromBytes(
    width: a.$2,
    height: a.$3,
    bytes: a.$1.buffer,
    numChannels: 4,
  );
  return img.encodeJpg(im, quality: 95);
}

/// Downloads the first frame of every picture sticker (needed to paint them into a photo).
/// A sticker that cannot be fetched is skipped.
Future<Map<String, ui.Image>> loadStickerImages(
  List<StoryOverlay> overlays,
) async {
  final out = <String, ui.Image>{};
  for (final o in overlays) {
    if (!o.isImage) continue;
    final url = o.still.isNotEmpty ? o.still : o.image;
    if (out.containsKey(url)) continue;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) continue;
      final bytes = await consolidateHttpClientResponseBytes(res);
      final codec = await ui.instantiateImageCodec(bytes);
      out[url] = (await codec.getNextFrame()).image;
      codec.dispose();
    } catch (_) {
      // skipped
    } finally {
      client.close(force: true);
    }
  }
  return out;
}

/// Burns [overlays] into a JPEG and returns the new file (the original is not touched).
Future<File> bakeOverlays(File jpeg, List<StoryOverlay> overlays) async {
  if (overlays.isEmpty) return jpeg;
  final codec = await ui.instantiateImageCodec(await jpeg.readAsBytes());
  final frame = await codec.getNextFrame();
  final base = frame.image;
  final w = base.width;
  final h = base.height;
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.drawImage(base, Offset.zero, Paint()..filterQuality = FilterQuality.high);
  final stickers = await loadStickerImages(overlays);
  paintOverlays(
    canvas,
    Size(w.toDouble(), h.toDouble()),
    overlays,
    images: stickers,
  );
  final out = await rec.endRecording().toImage(w, h);
  for (final p in stickers.values) {
    p.dispose();
  }
  final data = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
  base.dispose();
  out.dispose();
  codec.dispose();
  if (data == null) throw const FormatException('Could not draw on this photo');
  final raw = data.buffer.asUint8List();
  final bytes = await Isolate.run(() => _encode((raw, w, h)));
  final f = File(
    '${Directory.systemTemp.path}/instantgram_text_${DateTime.now().microsecondsSinceEpoch}.jpg',
  );
  await f.writeAsBytes(bytes, flush: true);
  return f;
}

/// The final picture of a photo: its [edits] (crop, filter, adjust) and its [overlays] baked
/// in. Without any change the original file is returned.
Future<File> finishPhoto(
  File original,
  PhotoEdits? edits,
  List<StoryOverlay> overlays,
) async {
  final e = edits ?? PhotoEdits();
  if (e.isEmpty && overlays.isEmpty) return original;
  final edited = await PhotoEditor.render(original, e);
  if (overlays.isEmpty) return edited;
  try {
    return await bakeOverlays(edited, overlays);
  } finally {
    if (overlays.isNotEmpty) {
      try {
        await edited.delete();
      } catch (_) {}
    }
  }
}

