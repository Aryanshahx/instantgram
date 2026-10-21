import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../../core/services/vision_service.dart';
import '../../shared/widgets/face_effects.dart';

/// v0.0.1 effects: green screen backgrounds (a photo from the gallery or
/// one of these colours).
const List<List<Color>> kGreenGradients = [
  [Color(0xFF0F2027), Color(0xFF2C5364)],
  [Color(0xFFFF5F6D), Color(0xFFFFC371)],
  [Color(0xFF8E2DE2), Color(0xFF4A00E0)],
  [Color(0xFF11998E), Color(0xFF38EF7D)],
  [Color(0xFFFC466B), Color(0xFF3F5EFB)],
  [Color(0xFFF7971E), Color(0xFFFFD200)],
  [Color(0xFF000000), Color(0xFF434343)],
];

/// What is behind you on the green screen.
class GreenBackground {
  const GreenBackground({this.file, this.gradient = 0});
  final File? file;
  final int gradient;

  List<Color> get colors =>
      kGreenGradients[gradient.clamp(0, kGreenGradients.length - 1)];

  LinearGradient get linear => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: colors,
  );
}

/// The live background behind you in the camera.
class GreenBackdrop extends StatelessWidget {
  const GreenBackdrop({super.key, required this.background});
  final GreenBackground background;

  @override
  Widget build(BuildContext context) {
    final f = background.file;
    if (f != null) {
      return Image.file(f, fit: BoxFit.cover, gaplessPlayback: true);
    }
    return DecoratedBox(decoration: BoxDecoration(gradient: background.linear));
  }
}

/// Background effects: what each one is called on screen.
const Map<String, String> kBgEffectNames = {
  'green': 'Green screen',
  'blur': 'Blur',
  'mono': 'Color pop',
  'spot': 'Spotlight',
};

/// Colour change for "Color pop" (black and white behind you).
const ColorFilter kMonoFilter = ColorFilter.matrix(<double>[
  0.299, 0.587, 0.114, 0, 0, //
  0.299, 0.587, 0.114, 0, 0, //
  0.299, 0.587, 0.114, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// "Spotlight": dark behind you.
const ColorFilter kSpotFilter = ColorFilter.matrix(<double>[
  0.22, 0, 0, 0, 0, //
  0, 0.22, 0, 0, 0, //
  0, 0, 0.22, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// The green screen background as a picture file (for videos). A photo
/// is used as it is; a colour is drawn into a small PNG.
Future<String> greenBackgroundFile(GreenBackground bg) async {
  final f = bg.file;
  if (f != null) return f.path;
  const size = Size(540, 960);
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec, Offset.zero & size);
  canvas.drawRect(
    Offset.zero & size,
    Paint()..shader = bg.linear.createShader(Offset.zero & size),
  );
  final image = await rec.endRecording().toImage(540, 960);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (data == null) throw const VisionException("Couldn't make the background");
  final dir = await getTemporaryDirectory();
  final out = File('${dir.path}/fx_bg_${bg.gradient}.png');
  await out.writeAsBytes(data.buffer.asUint8List(), flush: true);
  return out.path;
}

/// Mask bytes (255 = person) -> a picture whose see-through parts are the
/// background.
Future<ui.Image> maskToImage(Uint8List mask, int w, int h) {
  final n = w * h;
  final rgba = Uint8List(n * 4);
  for (var i = 0, j = 0; i < n; i++, j += 4) {
    rgba[j] = 255;
    rgba[j + 1] = 255;
    rgba[j + 2] = 255;
    rgba[j + 3] = mask[i];
  }
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, done.complete);
  return done.future;
}

/// Matrix that shows a picture [src] big with BoxFit.cover in [dst].
Float64List coverMatrix(Size src, Size dst) {
  final s = math.max(dst.width / src.width, dst.height / src.height);
  final dx = (dst.width - src.width * s) / 2;
  final dy = (dst.height - src.height * s) / 2;
  return (Matrix4.diagonal3Values(
    s,
    s,
    1,
  )..setTranslationRaw(dx, dy, 0)).storage;
}

Rect coverRect(Size src, Rect dst) {
  final s = math.max(dst.width / src.width, dst.height / src.height);
  final w = src.width * s, h = src.height * s;
  return Rect.fromLTWH(
    dst.left + (dst.width - w) / 2,
    dst.top + (dst.height - h) / 2,
    w,
    h,
  );
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

/// Result of [bakeEffects].
class BakeResult {
  const BakeResult(this.file, {required this.faces, required this.cutOut});
  final File file;

  /// Faces that got the effect.
  final int faces;

  /// The background effect worked (a person was found).
  final bool cutOut;
}

/// Puts the face effect / background effect ([bg], see [kBgEffects])
/// INTO a photo (a new JPEG).
Future<BakeResult> bakeEffects(
  String path, {
  required String effect,
  String bg = '',
  GreenBackground green = const GreenBackground(),
  VisionService? vision,
}) async {
  final v = vision ?? VisionService.instance;
  final face = isFaceEffect(effect);
  final r = await v.photo(path, face: face, segment: bg.isNotEmpty);
  final src = r.path.isNotEmpty ? r.path : path;
  final photo = await _decode(await File(src).readAsBytes());
  final w = photo.width, h = photo.height;
  final full = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec, full);
  final mask = r.mask;
  var cutOut = false;
  if (bg.isNotEmpty && mask != null) {
    cutOut = true;
    final bgFile = green.file;
    if (bg == 'blur') {
      final sigma = math.max(w, h) / 70;
      canvas.saveLayer(full, Paint());
      canvas.drawImage(
        photo,
        Offset.zero,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: TileMode.clamp,
          ),
      );
      canvas.restore();
    } else if (bg == 'mono' || bg == 'spot') {
      canvas.drawImage(
        photo,
        Offset.zero,
        Paint()..colorFilter = bg == 'mono' ? kMonoFilter : kSpotFilter,
      );
    } else if (bgFile != null) {
      final bg = await _decode(await bgFile.readAsBytes());
      final s = Size(bg.width.toDouble(), bg.height.toDouble());
      canvas.drawImageRect(
        bg,
        Offset.zero & s,
        coverRect(s, full),
        Paint()..filterQuality = FilterQuality.medium,
      );
      bg.dispose();
    } else {
      canvas.drawRect(full, Paint()..shader = green.linear.createShader(full));
    }
    canvas.saveLayer(full, Paint());
    canvas.drawImage(photo, Offset.zero, Paint());
    final m = await maskToImage(mask, r.maskWidth, r.maskHeight);
    canvas.drawImageRect(
      m,
      Rect.fromLTWH(0, 0, r.maskWidth.toDouble(), r.maskHeight.toDouble()),
      full,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
    m.dispose();
  } else {
    canvas.drawImage(photo, Offset.zero, Paint());
  }
  if (face && r.faces.isNotEmpty) {
    paintFaceEffects(canvas, Size(w.toDouble(), h.toDouble()), effect, r.faces);
  }
  final out = await rec.endRecording().toImage(w, h);
  final data = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
  out.dispose();
  photo.dispose();
  if (data == null) throw const VisionException("Couldn't make the photo");
  final raw = data.buffer.asUint8List();
  final jpg = await Isolate.run(
    () => img.encodeJpg(
      img.Image.fromBytes(
        width: w,
        height: h,
        bytes: raw.buffer,
        numChannels: 4,
      ),
      quality: 92,
    ),
  );
  final dir = await getTemporaryDirectory();
  final file = File(
    '${dir.path}/fx_${DateTime.now().millisecondsSinceEpoch}.jpg',
  );
  await file.writeAsBytes(jpg, flush: true);
  if (r.path.isNotEmpty && r.path != path) {
    try {
      File(r.path).deleteSync();
    } catch (_) {}
  }
  return BakeResult(file, faces: face ? r.faces.length : 0, cutOut: cutOut);
}
