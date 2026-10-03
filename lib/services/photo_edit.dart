import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

/// A colour filter preset. [matrix] is a 4x5 colour matrix (the same format Flutter's
/// `ColorFilter.matrix` uses), so the live preview and the saved photo look identical.
class PhotoFilter {
  const PhotoFilter(this.name, this.matrix);
  final String name;
  final List<double> matrix;
}

const List<double> kIdentityMatrix = [
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0,
  0, 0, 1, 0, 0,
  0, 0, 0, 1, 0,
];

List<double> saturationMatrix(double s) {
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  return [
    lr * (1 - s) + s, lg * (1 - s), lb * (1 - s), 0, 0, //
    lr * (1 - s), lg * (1 - s) + s, lb * (1 - s), 0, 0,
    lr * (1 - s), lg * (1 - s), lb * (1 - s) + s, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

List<double> contrastMatrix(double c) {
  final t = 128 * (1 - c);
  return [
    c, 0, 0, 0, t, //
    0, c, 0, 0, t,
    0, 0, c, 0, t,
    0, 0, 0, 1, 0,
  ];
}

List<double> brightnessMatrix(double b) {
  final t = b * 80; // b is -1..1
  return [
    1, 0, 0, 0, t, //
    0, 1, 0, 0, t,
    0, 0, 1, 0, t,
    0, 0, 0, 1, 0,
  ];
}

/// Result of applying [first] and then [second].
List<double> thenMatrix(List<double> first, List<double> second) {
  final out = List<double>.filled(20, 0);
  for (var r = 0; r < 4; r++) {
    for (var c = 0; c < 5; c++) {
      var v = 0.0;
      for (var k = 0; k < 4; k++) {
        v += second[r * 5 + k] * first[k * 5 + c];
      }
      if (c == 4) v += second[r * 5 + 4];
      out[r * 5 + c] = v;
    }
  }
  return out;
}

final List<PhotoFilter> kPhotoFilters = [
  const PhotoFilter('Original', kIdentityMatrix),
  PhotoFilter('Vivid', thenMatrix(saturationMatrix(1.35), contrastMatrix(1.1))),
  const PhotoFilter('Warm', [
    1.08, 0, 0, 0, 6, //
    0, 1.0, 0, 0, 0,
    0, 0, 0.88, 0, -6,
    0, 0, 0, 1, 0,
  ]),
  const PhotoFilter('Cool', [
    0.9, 0, 0, 0, -4, //
    0, 1.0, 0, 0, 0,
    0, 0, 1.12, 0, 8,
    0, 0, 0, 1, 0,
  ]),
  PhotoFilter('Mono', saturationMatrix(0)),
  PhotoFilter('Noir', thenMatrix(saturationMatrix(0), contrastMatrix(1.35))),
  PhotoFilter('Fade', thenMatrix(contrastMatrix(0.85), brightnessMatrix(0.22))),
  const PhotoFilter('Volt', [
    1.0, 0.04, 0, 0, 4, //
    0, 1.06, 0, 0, 6,
    0, 0, 0.82, 0, -4,
    0, 0, 0, 1, 0,
  ]),
];

/// Everything the photo editor can change. Cheap to copy.
class PhotoEdits {
  PhotoEdits({
    this.turns = 0,
    this.flip = false,
    this.crop = const Rect.fromLTWH(0, 0, 1, 1),
    this.filter = 0,
    this.brightness = 0,
    this.contrast = 1,
    this.saturation = 1,
  });

  /// Clockwise quarter turns (0-3), applied first.
  int turns;

  /// Mirrored left-to-right after the turns.
  bool flip;

  /// Crop rectangle as fractions (0..1) of the turned and flipped photo.
  Rect crop;

  int filter;

  /// -1..1 (0 = unchanged)
  double brightness;

  /// 0.5..1.5 (1 = unchanged)
  double contrast;

  /// 0..2 (1 = unchanged)
  double saturation;

  PhotoEdits copy() => PhotoEdits(
    turns: turns,
    flip: flip,
    crop: crop,
    filter: filter,
    brightness: brightness,
    contrast: contrast,
    saturation: saturation,
  );

  bool get hasCrop =>
      crop.left > 0.001 ||
      crop.top > 0.001 ||
      crop.width < 0.999 ||
      crop.height < 0.999;

  bool get hasColor =>
      filter != 0 ||
      brightness.abs() > 0.001 ||
      (contrast - 1).abs() > 0.001 ||
      (saturation - 1).abs() > 0.001;

  bool get isEmpty => turns % 4 == 0 && !flip && !hasCrop && !hasColor;

  /// The filter, then saturation, contrast and brightness on top of it.
  List<double> get colorMatrix {
    var m = kPhotoFilters[filter.clamp(0, kPhotoFilters.length - 1)].matrix;
    if ((saturation - 1).abs() > 0.001) {
      m = thenMatrix(m, saturationMatrix(saturation));
    }
    if ((contrast - 1).abs() > 0.001) {
      m = thenMatrix(m, contrastMatrix(contrast));
    }
    if (brightness.abs() > 0.001) {
      m = thenMatrix(m, brightnessMatrix(brightness));
    }
    return m;
  }
}

/// A small, upright copy of the photo for the live preview (EXIF rotation already applied).
class PhotoProxy {
  const PhotoProxy(this.file, this.width, this.height);
  final File file;
  final int width;
  final int height;
}

class PhotoEditor {
  /// Longest side of the saved photo. Phones take 12-50 megapixel photos; this keeps editing
  /// from running out of memory and still leaves a 16 megapixel result.
  static const int maxSide = 4096;

  /// Builds the preview copy (about 1280 px) off the main thread.
  static Future<PhotoProxy> makeProxy(File original) async {
    final bytes = await original.readAsBytes();
    final r = await Isolate.run(() => _proxy(bytes));
    final dir = Directory.systemTemp.path;
    final f = File(
      '$dir/instantgram_proxy_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await f.writeAsBytes(r.bytes, flush: true);
    return PhotoProxy(f, r.w, r.h);
  }

  /// Applies [edits] to the original photo and saves a high quality JPEG (quality 95).
  static Future<File> render(File original, PhotoEdits edits) async {
    final bytes = await original.readAsBytes();
    final args = <double>[
      edits.turns.toDouble(),
      edits.flip ? 1 : 0,
      edits.crop.left,
      edits.crop.top,
      edits.crop.width,
      edits.crop.height,
      ...edits.colorMatrix,
    ];
    final out = await Isolate.run(() => renderBytes(bytes, args));
    final dir = Directory.systemTemp.path;
    final f = File(
      '$dir/instantgram_edit_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await f.writeAsBytes(out, flush: true);
    return f;
  }

  static ({Uint8List bytes, int w, int h}) _proxy(Uint8List bytes) {
    var im = img.decodeImage(bytes);
    if (im == null) throw const FormatException('Cannot read this photo');
    im = img.bakeOrientation(im);
    if (im.width > 1280 || im.height > 1280) {
      im = im.width >= im.height
          ? img.copyResize(
              im,
              width: 1280,
              interpolation: img.Interpolation.average,
            )
          : img.copyResize(
              im,
              height: 1280,
              interpolation: img.Interpolation.average,
            );
    }
    return (bytes: img.encodeJpg(im, quality: 88), w: im.width, h: im.height);
  }

  /// Pure function (runs inside an isolate, and directly in tests).
  /// [a] = [turns, flip, cropLeft, cropTop, cropWidth, cropHeight, ...20 matrix values].
  static Uint8List renderBytes(Uint8List bytes, List<double> a) {
    var im = img.decodeImage(bytes);
    if (im == null) throw const FormatException('Cannot read this photo');
    im = img.bakeOrientation(im);

    if (im.width > maxSide || im.height > maxSide) {
      im = im.width >= im.height
          ? img.copyResize(
              im,
              width: maxSide,
              interpolation: img.Interpolation.average,
            )
          : img.copyResize(
              im,
              height: maxSide,
              interpolation: img.Interpolation.average,
            );
    }

    final turns = a[0].round() % 4;
    if (turns != 0) im = img.copyRotate(im, angle: 90.0 * turns);
    if (a[1] > 0.5) im = img.flipHorizontal(im);

    final cl = a[2], ct = a[3], cw = a[4], ch = a[5];
    if (cl > 0.001 || ct > 0.001 || cw < 0.999 || ch < 0.999) {
      final x = (cl * im.width).round().clamp(0, im.width - 1);
      final y = (ct * im.height).round().clamp(0, im.height - 1);
      final w = (cw * im.width).round().clamp(1, im.width - x);
      final h = (ch * im.height).round().clamp(1, im.height - y);
      im = img.copyCrop(im, x: x, y: y, width: w, height: h);
    }

    final m = a.sublist(6);
    var identity = true;
    for (var i = 0; i < 20; i++) {
      if ((m[i] - kIdentityMatrix[i]).abs() > 1e-6) identity = false;
    }
    if (!identity) {
      im = im.convert(format: img.Format.uint8, numChannels: 3);
      final px = im.toUint8List();
      final m0 = m[0], m1 = m[1], m2 = m[2], m4 = m[4];
      final m5 = m[5], m6 = m[6], m7 = m[7], m9 = m[9];
      final m10 = m[10], m11 = m[11], m12 = m[12], m14 = m[14];
      for (var i = 0; i + 2 < px.length; i += 3) {
        final r = px[i], g = px[i + 1], b = px[i + 2];
        final nr = m0 * r + m1 * g + m2 * b + m4;
        final ng = m5 * r + m6 * g + m7 * b + m9;
        final nb = m10 * r + m11 * g + m12 * b + m14;
        px[i] = nr < 0 ? 0 : (nr > 255 ? 255 : nr.round());
        px[i + 1] = ng < 0 ? 0 : (ng > 255 ? 255 : ng.round());
        px[i + 2] = nb < 0 ? 0 : (nb > 255 ? 255 : nb.round());
      }
    }
    return img.encodeJpg(im, quality: 95);
  }

  /// Reads the proportions of a photo as it will be displayed (EXIF rotation included),
  /// without decoding the whole picture. Null if it cannot be read.
  static Future<Size?> probeSize(File file) {
    final done = Completer<Size?>();
    final stream = ResizeImage(
      FileImage(file),
      width: 200,
      allowUpscaling: false,
    ).resolve(ImageConfiguration.empty);
    late final ImageStreamListener l;
    l = ImageStreamListener(
      (info, _) {
        stream.removeListener(l);
        if (!done.isCompleted) {
          done.complete(
            Size(info.image.width.toDouble(), info.image.height.toDouble()),
          );
        }
      },
      onError: (_, _) {
        stream.removeListener(l);
        if (!done.isCompleted) done.complete(null);
      },
    );
    stream.addListener(l);
    return done.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () {
        stream.removeListener(l);
        return null;
      },
    );
  }

  /// Largest centred crop of a photo with proportions [photoAspect] (width / height) that
  /// has the proportions [target] (width / height).
  static Rect cropFor(double photoAspect, double target) {
    if (target <= 0 || photoAspect <= 0) {
      return const Rect.fromLTWH(0, 0, 1, 1);
    }
    var w = 1.0, h = 1.0;
    if (target > photoAspect) {
      h = photoAspect / target;
    } else {
      w = target / photoAspect;
    }
    return Rect.fromLTWH((1 - w) / 2, (1 - h) / 2, w, h);
  }

  static double clamp01(double v) => math.min(1, math.max(0, v));
}
