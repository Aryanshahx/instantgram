import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 4x5 color matrices (same format as [ColorFilter.matrix]).
class ColorMatrix {
  ColorMatrix._();

  static const List<double> identity = [
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, 1, 0, //
  ];

  static bool isIdentity(List<double> m) {
    for (var i = 0; i < 20; i++) {
      if ((m[i] - identity[i]).abs() > 0.0001) return false;
    }
    return true;
  }

  /// Result = a applied AFTER b.
  static List<double> multiply(List<double> a, List<double> b) {
    final out = List<double>.filled(20, 0);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 5; c++) {
        var v = 0.0;
        for (var k = 0; k < 4; k++) {
          v += a[r * 5 + k] * b[k * 5 + c];
        }
        if (c == 4) v += a[r * 5 + 4];
        out[r * 5 + c] = v;
      }
    }
    return out;
  }

  static List<double> chain(List<List<double>> ms) {
    var out = identity;
    for (final m in ms) {
      out = multiply(m, out);
    }
    return out;
  }

  /// v: -1..1
  static List<double> brightness(double v) {
    final o = v * 70;
    return [1, 0, 0, 0, o, 0, 1, 0, 0, o, 0, 0, 1, 0, o, 0, 0, 0, 1, 0];
  }

  /// v: -1..1
  static List<double> contrast(double v) {
    final s = 1 + v * 0.6;
    final o = 128 * (1 - s);
    return [s, 0, 0, 0, o, 0, s, 0, 0, o, 0, 0, s, 0, o, 0, 0, 0, 1, 0];
  }

  /// s: 0 = grey, 1 = normal, 2 = very colorful
  static List<double> saturation(double s) {
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final r = (1 - s) * lr, g = (1 - s) * lg, b = (1 - s) * lb;
    return [
      r + s, g, b, 0, 0, //
      r, g + s, b, 0, 0, //
      r, g, b + s, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }

  /// v: -1 (cool) .. 1 (warm)
  static List<double> warmth(double v) {
    final o = v * 28;
    return [1, 0, 0, 0, o, 0, 1, 0, 0, o * 0.3, 0, 0, 1, 0, -o, 0, 0, 0, 1, 0];
  }

  /// v: 0..1 (lifts the blacks, softer look)
  static List<double> fade(double v) {
    final s = 1 - v * 0.3;
    final o = v * 50;
    return [s, 0, 0, 0, o, 0, s, 0, 0, o, 0, 0, s, 0, o, 0, 0, 0, 1, 0];
  }

  static List<double> tint(double r, double g, double b) =>
      [r, 0, 0, 0, 0, 0, g, 0, 0, 0, 0, 0, b, 0, 0, 0, 0, 0, 1, 0];

  static const List<double> sepia = [
    0.393, 0.769, 0.189, 0, 0, //
    0.349, 0.686, 0.168, 0, 0, //
    0.272, 0.534, 0.131, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}

class FilterPreset {
  const FilterPreset(this.name, this.matrix);
  final String name;
  final List<double> matrix;
}

final List<FilterPreset> kFilterPresets = [
  const FilterPreset('Normal', ColorMatrix.identity),
  FilterPreset(
      'Vivid',
      ColorMatrix.chain(
          [ColorMatrix.saturation(1.45), ColorMatrix.contrast(0.25)])),
  FilterPreset(
      'Warm',
      ColorMatrix.chain(
          [ColorMatrix.warmth(0.8), ColorMatrix.saturation(1.1)])),
  FilterPreset(
      'Cool',
      ColorMatrix.chain(
          [ColorMatrix.warmth(-0.8), ColorMatrix.brightness(0.05)])),
  FilterPreset('Mono', ColorMatrix.saturation(0)),
  FilterPreset(
      'Noir',
      ColorMatrix.chain(
          [ColorMatrix.saturation(0), ColorMatrix.contrast(0.6)])),
  FilterPreset(
      'Vintage',
      ColorMatrix.chain([
        ColorMatrix.sepia,
        ColorMatrix.saturation(1.2),
        ColorMatrix.fade(0.4),
      ])),
  FilterPreset(
      'Faded',
      ColorMatrix.chain(
          [ColorMatrix.fade(0.8), ColorMatrix.saturation(0.75)])),
  FilterPreset(
      'Lime',
      ColorMatrix.chain([
        ColorMatrix.tint(0.95, 1.1, 0.85),
        ColorMatrix.contrast(0.15),
      ])),
  FilterPreset(
      'Dusk',
      ColorMatrix.chain([
        ColorMatrix.tint(1.1, 0.9, 1.12),
        ColorMatrix.fade(0.2),
      ])),
  FilterPreset(
      'Drama',
      ColorMatrix.chain([
        ColorMatrix.contrast(0.7),
        ColorMatrix.saturation(0.8),
        ColorMatrix.brightness(-0.08),
      ])),
  FilterPreset('Sepia', ColorMatrix.sepia),
];

/// All color edits of one photo or video.
class ColorEdits {
  const ColorEdits({
    this.preset = 0,
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.warmth = 0,
    this.fade = 0,
  });

  final int preset;
  final double brightness; // -1..1
  final double contrast; // -1..1
  final double saturation; // -1..1
  final double warmth; // -1..1
  final double fade; // 0..1

  bool get isNone =>
      preset == 0 &&
      brightness == 0 &&
      contrast == 0 &&
      saturation == 0 &&
      warmth == 0 &&
      fade == 0;

  ColorEdits copyWith({
    int? preset,
    double? brightness,
    double? contrast,
    double? saturation,
    double? warmth,
    double? fade,
  }) =>
      ColorEdits(
        preset: preset ?? this.preset,
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        warmth: warmth ?? this.warmth,
        fade: fade ?? this.fade,
      );

  List<double> get matrix {
    final p = kFilterPresets[preset.clamp(0, kFilterPresets.length - 1)];
    return ColorMatrix.chain([
      p.matrix,
      if (brightness != 0) ColorMatrix.brightness(brightness),
      if (contrast != 0) ColorMatrix.contrast(contrast),
      if (saturation != 0) ColorMatrix.saturation(1 + saturation),
      if (warmth != 0) ColorMatrix.warmth(warmth),
      if (fade != 0) ColorMatrix.fade(fade),
    ]);
  }

  /// null when nothing changed (store nothing).
  List<double>? get matrixOrNull {
    if (isNone) return null;
    final m = matrix;
    return ColorMatrix.isIdentity(m)
        ? null
        : m.map((v) => (v * 10000).roundToDouble() / 10000).toList();
  }
}

/// Wraps [child] in a color filter (does nothing for null / identity).
Widget applyMatrix(List<double>? m, Widget child) {
  if (m == null || m.length != 20 || ColorMatrix.isIdentity(m)) return child;
  return ColorFiltered(colorFilter: ColorFilter.matrix(m), child: child);
}

double degToRad(double d) => d * math.pi / 180;
