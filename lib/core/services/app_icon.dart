import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

/// v0.15: change the launcher icon (MainActivity.kt activity aliases).
abstract final class AppIcons {
  static const _ch = MethodChannel('instantgram/system');

  /// id -> name. Ids must match MainActivity.kt + AndroidManifest.xml.
  static const Map<String, String> all = {
    'default': 'Classic',
    'night': 'Night',
    'sunset': 'Sunset',
    'ocean': 'Ocean',
    'berry': 'Berry',
    'mono': 'Light',
  };

  static String normalize(Object? id) =>
      id is String && all.containsKey(id) ? id : 'default';

  static String asset(String id) =>
      'assets/images/app_icon_${normalize(id)}.png';

  /// Tests.
  @visibleForTesting
  static Future<String> Function()? debugGet;
  @visibleForTesting
  static Future<String> Function(String id)? debugSet;

  static Future<String> current() async {
    if (debugGet != null) return debugGet!();
    try {
      return normalize(await _ch.invokeMethod<String>('getAppIcon'));
    } catch (_) {
      return 'default';
    }
  }

  // ------------------------------------------- v0.16: your own picture

  @visibleForTesting
  static Future<bool> Function(Uint8List png)? debugPin;

  /// Can this phone add a home-screen icon (Android 8+ launchers)?
  static Future<bool> canPinCustom() async {
    if (debugPin != null) return true;
    try {
      return await _ch.invokeMethod<bool>('canPinShortcut') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Adds a home-screen icon with [png] (from [customIconPng]). True when
  /// the phone shows its "Add to home screen" question.
  static Future<bool> pinCustom(Uint8List png) async {
    if (debugPin != null) return debugPin!(png);
    try {
      return await _ch.invokeMethod<bool>('pinShortcut', {
            'png': png,
            'label': 'InstantGram',
          }) ??
          false;
    } catch (e) {
      debugPrint('custom icon: $e');
      return false;
    }
  }

  /// Size of the icon picture (Android adaptive icon: 108 dp at 4x).
  static const int customSize = 432;

  /// Picture -> square icon PNG. The photo fills the middle 80% (phones
  /// cut the edges into a circle / rounded square); the rest is the
  /// photo's edge colour. Null = not a picture.
  static Uint8List? customIconPng(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final src = img.bakeOrientation(decoded);
    final side = math.min(src.width, src.height);
    final square = img.copyCrop(
      src,
      x: (src.width - side) ~/ 2,
      y: (src.height - side) ~/ 2,
      width: side,
      height: side,
    );
    final inner = (customSize * 0.8).round();
    final photo = img.copyResize(
      square,
      width: inner,
      height: inner,
      interpolation: img.Interpolation.average,
    );
    // average colour of the photo's border
    var r = 0, g = 0, b = 0, n = 0;
    for (var i = 0; i < inner; i += 4) {
      for (final (x, y) in [(i, 0), (i, inner - 1), (0, i), (inner - 1, i)]) {
        final p = photo.getPixel(x, y);
        r += p.r.toInt();
        g += p.g.toInt();
        b += p.b.toInt();
        n++;
      }
    }
    final canvas = img.Image(width: customSize, height: customSize);
    img.fill(
      canvas,
      color: img.ColorRgb8(
        r ~/ math.max(1, n),
        g ~/ math.max(1, n),
        b ~/ math.max(1, n),
      ),
    );
    final off = (customSize - inner) ~/ 2;
    img.compositeImage(canvas, photo, dstX: off, dstY: off);
    return img.encodePng(canvas);
  }

  /// Returns the icon now in use.
  static Future<String> set(String id) async {
    final want = normalize(id);
    if (debugSet != null) return debugSet!(want);
    try {
      return normalize(
        await _ch.invokeMethod<String>('setAppIcon', {'icon': want}),
      );
    } catch (e) {
      debugPrint('app icon: $e');
      return current();
    }
  }
}
