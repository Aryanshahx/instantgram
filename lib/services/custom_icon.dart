import 'dart:typed_data';
import 'dart:ui' as ui;

/// Size of a custom icon picture (the picked photo is cut square and scaled to this).
const int kCustomIconSize = 512;

/// The middle square of an image, as [kCustomIconSize] x [kCustomIconSize] PNG bytes.
Future<Uint8List> squareIcon(Uint8List bytes) async {
  final img = await _decode(bytes);
  final side = img.width < img.height ? img.width : img.height;
  final src = ui.Rect.fromLTWH(
    (img.width - side) / 2,
    (img.height - side) / 2,
    side.toDouble(),
    side.toDouble(),
  );
  const s = kCustomIconSize * 1.0;
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawImageRect(
    img,
    src,
    const ui.Rect.fromLTWH(0, 0, s, s),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  return _png(rec, kCustomIconSize);
}

/// The launcher picture for Android (adaptive icon): the square in the middle 2/3 (the part
/// every launcher shape shows), the same picture blurred behind it to the edges.
Future<Uint8List> adaptiveIcon(Uint8List square) async {
  final img = await _decode(square);
  const size = 768;
  const s = size * 1.0;
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  final src = ui.Rect.fromLTWH(
    0,
    0,
    img.width.toDouble(),
    img.height.toDouble(),
  );
  c.drawImageRect(
    img,
    src,
    const ui.Rect.fromLTWH(0, 0, s, s),
    ui.Paint()
      ..imageFilter = ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40)
      ..filterQuality = ui.FilterQuality.medium,
  );
  c.drawImageRect(
    img,
    src,
    const ui.Rect.fromLTWH(s / 6, s / 6, s * 2 / 3, s * 2 / 3),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  return _png(rec, size);
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  return (await codec.getNextFrame()).image;
}

Future<Uint8List> _png(ui.PictureRecorder rec, int size) async {
  final out = await rec.endRecording().toImage(size, size);
  final data = await out.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
