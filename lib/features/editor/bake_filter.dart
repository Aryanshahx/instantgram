import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'filters.dart';

class _Args {
  const _Args(this.bytes, this.m);
  final Uint8List bytes;
  final List<double> m;
}

Uint8List? _bake(_Args a) {
  final im = img.decodeImage(a.bytes);
  if (im == null) return null;
  final m = a.m;
  int c(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());
  for (final p in im) {
    final r = p.r.toDouble(), g = p.g.toDouble(), b = p.b.toDouble();
    p
      ..r = c(m[0] * r + m[1] * g + m[2] * b + m[4])
      ..g = c(m[5] * r + m[6] * g + m[7] * b + m[9])
      ..b = c(m[10] * r + m[11] * g + m[12] * b + m[14]);
  }
  return img.encodeJpg(im, quality: 88);
}

/// Applies a color matrix to a photo file (returns a new JPG file).
/// Returns [src] unchanged when there is no filter or it fails.
Future<File> bakeFilter(File src, List<double>? m) async {
  if (m == null || m.length != 20 || ColorMatrix.isIdentity(m)) return src;
  try {
    final out = await compute(_bake, _Args(await src.readAsBytes(), m));
    if (out == null) return src;
    final dir = await Directory.systemTemp.createTemp('ig_bake');
    final f = File(
      '${dir.path}/cover_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await f.writeAsBytes(out, flush: true);
    return f;
  } catch (_) {
    return src;
  }
}
