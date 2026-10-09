import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';

import '../services/photo_edit.dart';
import 'story.dart';

/// Colour changes of a video (filter, brightness, contrast, saturation). They are not baked
/// into the file: they are applied while the clip plays, so the video stays untouched.
class VideoLook {
  const VideoLook({
    this.filter = 0,
    this.brightness = 0,
    this.contrast = 1,
    this.saturation = 1,
  });

  /// Index in [kPhotoFilters].
  final int filter;
  final double brightness;
  final double contrast;
  final double saturation;

  bool get isEmpty =>
      filter == 0 &&
      brightness.abs() < 0.001 &&
      (contrast - 1).abs() < 0.001 &&
      (saturation - 1).abs() < 0.001;

  /// The 4x5 colour matrix (same maths as the photo editor).
  List<double> get matrix => PhotoEdits(
    filter: filter,
    brightness: brightness,
    contrast: contrast,
    saturation: saturation,
  ).colorMatrix;

  Map<String, Object> toMap() => {
    'f': filter,
    'b': double.parse(brightness.toStringAsFixed(3)),
    'c': double.parse(contrast.toStringAsFixed(3)),
    's': double.parse(saturation.toStringAsFixed(3)),
  };

  static VideoLook? fromMap(Object? v) {
    if (v is! Map) return null;
    double d(Object? x, double fallback) => x is num ? x.toDouble() : fallback;
    final f = v['f'] is num ? (v['f'] as num).toInt() : 0;
    final look = VideoLook(
      filter: f.clamp(0, kPhotoFilters.length - 1),
      brightness: d(v['b'], 0).clamp(-1.0, 1.0),
      contrast: d(v['c'], 1).clamp(0.5, 1.5),
      saturation: d(v['s'], 1).clamp(0.0, 2.0),
    );
    return look.isEmpty ? null : look;
  }
}

// ------------------------------------------------------------------ animation

/// How a text, sticker or layer comes in and goes out (Edit > Animate).
class MotionAnim {
  const MotionAnim({this.inn = '', this.out = '', this.secs = 0.6});

  /// One of [kMotionKinds] ('' = none).
  final String inn;
  final String out;

  /// How long the coming in and the going out take.
  final double secs;

  bool get isEmpty => inn.isEmpty && out.isEmpty;

  MotionAnim copyWith({String? inn, String? out, double? secs}) => MotionAnim(
    inn: inn ?? this.inn,
    out: out ?? this.out,
    secs: secs ?? this.secs,
  );

  Map<String, Object> toMap() => {
    if (inn.isNotEmpty) 'i': inn,
    if (out.isNotEmpty) 'o': out,
    'd': double.parse(secs.toStringAsFixed(2)),
  };

  static MotionAnim? fromMap(Object? v) {
    if (v is! Map) return null;
    String kind(Object? x) =>
        x is String && kMotionKinds.containsKey(x) ? x : '';
    final a = MotionAnim(
      inn: kind(v['i']),
      out: kind(v['o']),
      secs: (v['d'] is num ? (v['d'] as num).toDouble() : 0.6).clamp(0.2, 3.0),
    );
    return a.isEmpty ? null : a;
  }
}

/// Animation kinds and their names.
const Map<String, String> kMotionKinds = {
  'fade': 'Fade',
  'up': 'Slide up',
  'down': 'Slide down',
  'left': 'Slide left',
  'right': 'Slide right',
  'zoom': 'Zoom',
  'pop': 'Pop',
  'spin': 'Spin',
  'bounce': 'Bounce',
  'blur': 'Flash',
};

/// Where an animated item is at one moment: shift (part of the picture), size, turn, see-through.
class MotionFrame {
  const MotionFrame({
    this.opacity = 1,
    this.dx = 0,
    this.dy = 0,
    this.scale = 1,
    this.turns = 0,
  });
  static const MotionFrame rest = MotionFrame();
  final double opacity;
  final double dx;
  final double dy;
  final double scale;
  final double turns;

  bool get isRest =>
      opacity >= 0.999 &&
      dx.abs() < 1e-4 &&
      dy.abs() < 1e-4 &&
      (scale - 1).abs() < 1e-4 &&
      turns.abs() < 1e-4;
}

/// [kind] at [p] (0 = start of coming in, 1 = in place). [leaving] mirrors the direction.
MotionFrame _motion(String kind, double p, bool leaving) {
  final q = p.clamp(0.0, 1.0);
  final dir = leaving ? -1.0 : 1.0;
  switch (kind) {
    case 'fade':
      return MotionFrame(opacity: Curves.easeOut.transform(q));
    case 'up':
      final e = Curves.easeOutCubic.transform(q);
      return MotionFrame(opacity: q, dy: dir * (1 - e) * 0.18);
    case 'down':
      final e = Curves.easeOutCubic.transform(q);
      return MotionFrame(opacity: q, dy: -dir * (1 - e) * 0.18);
    case 'left':
      final e = Curves.easeOutCubic.transform(q);
      return MotionFrame(opacity: q, dx: dir * (1 - e) * 0.25);
    case 'right':
      final e = Curves.easeOutCubic.transform(q);
      return MotionFrame(opacity: q, dx: -dir * (1 - e) * 0.25);
    case 'zoom':
      final e = Curves.easeOutCubic.transform(q);
      return MotionFrame(opacity: q, scale: 0.3 + 0.7 * e);
    case 'pop':
      return MotionFrame(
        opacity: math.min(1, q * 3),
        scale: math.max(0.01, Curves.elasticOut.transform(q)),
      );
    case 'spin':
      final e = Curves.easeOutCubic.transform(q);
      return MotionFrame(
        opacity: q,
        scale: 0.2 + 0.8 * e,
        turns: dir * (1 - e) * 0.5,
      );
    case 'bounce':
      return MotionFrame(
        opacity: math.min(1, q * 4),
        dy: -(1 - Curves.bounceOut.transform(q)) * 0.3,
      );
    case 'blur':
      // a quick flash: bright and big, then settles
      return MotionFrame(
        opacity: q < 0.5 ? q * 2 : 1,
        scale: 1 + (1 - q) * 0.25,
      );
  }
  return MotionFrame.rest;
}

/// The frame of an item shown from [from] to [to] (seconds of the clip; [to] < 0 = until
/// [clipEnd]) at [sec].
MotionFrame motionAt(
  MotionAnim? a,
  double sec, {
  double from = 0,
  double to = -1,
  double clipEnd = 0,
}) {
  if (a == null || a.isEmpty) return MotionFrame.rest;
  final end = to >= 0 ? to : clipEnd;
  final d = a.secs <= 0 ? 0.6 : a.secs;
  if (a.inn.isNotEmpty && sec - from < d) {
    return _motion(a.inn, (sec - from) / d, false);
  }
  if (a.out.isNotEmpty && end > from && end - sec < d) {
    return _motion(a.out, (end - sec) / d, true);
  }
  return MotionFrame.rest;
}

// ------------------------------------------------------------------------ mask

/// Mask shapes and their names.
const Map<String, String> kMaskShapes = {
  'circle': 'Circle',
  'rect': 'Rectangle',
  'heart': 'Heart',
  'star': 'Star',
  'line': 'Split',
  'film': 'Band',
};

/// Shows only a shape of a clip or layer (Edit > Mask).
class LayerMask {
  const LayerMask({
    this.shape = 'circle',
    this.cx = 0.5,
    this.cy = 0.5,
    this.size = 0.7,
    this.feather = 0.05,
    this.invert = false,
  });

  final String shape;

  /// Centre, as parts of the width and height.
  final double cx;
  final double cy;

  /// Size as a part of the shorter side.
  final double size;

  /// Soft edge, as a part of the shorter side.
  final double feather;

  /// Show everything except the shape.
  final bool invert;

  LayerMask copyWith({
    String? shape,
    double? cx,
    double? cy,
    double? size,
    double? feather,
    bool? invert,
  }) => LayerMask(
    shape: shape ?? this.shape,
    cx: cx ?? this.cx,
    cy: cy ?? this.cy,
    size: size ?? this.size,
    feather: feather ?? this.feather,
    invert: invert ?? this.invert,
  );

  Map<String, Object> toMap() => {
    's': shape,
    'x': _r(cx),
    'y': _r(cy),
    'z': _r(size),
    'f': _r(feather),
    if (invert) 'v': true,
  };

  static LayerMask? fromMap(Object? v) {
    if (v is! Map) return null;
    final shape = v['s'];
    if (shape is! String || !kMaskShapes.containsKey(shape)) return null;
    double d(Object? x, double f, double lo, double hi) =>
        (x is num ? x.toDouble() : f).clamp(lo, hi);
    return LayerMask(
      shape: shape,
      cx: d(v['x'], 0.5, 0, 1),
      cy: d(v['y'], 0.5, 0, 1),
      size: d(v['z'], 0.7, 0.05, 2),
      feather: d(v['f'], 0.05, 0, 0.5),
      invert: v['v'] == true,
    );
  }

  /// The shape in a box of [s].
  Path path(Size s) {
    final m = math.min(s.width, s.height);
    final c = Offset(cx * s.width, cy * s.height);
    final r = size * m / 2;
    switch (shape) {
      case 'rect':
        return Path()..addRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: c, width: r * 2, height: r * 1.4),
            Radius.circular(r * 0.12),
          ),
        );
      case 'heart':
        final p = Path();
        final w = r * 2;
        final top = c.dy - r * 0.55;
        p.moveTo(c.dx, top + w * 0.25);
        p.cubicTo(
          c.dx,
          top,
          c.dx - w * 0.5,
          top,
          c.dx - w * 0.5,
          top + w * 0.3,
        );
        p.cubicTo(
          c.dx - w * 0.5,
          top + w * 0.55,
          c.dx - w * 0.15,
          top + w * 0.7,
          c.dx,
          top + w * 0.85,
        );
        p.cubicTo(
          c.dx + w * 0.15,
          top + w * 0.7,
          c.dx + w * 0.5,
          top + w * 0.55,
          c.dx + w * 0.5,
          top + w * 0.3,
        );
        p.cubicTo(c.dx + w * 0.5, top, c.dx, top, c.dx, top + w * 0.25);
        return p..close();
      case 'star':
        final p = Path();
        for (var i = 0; i < 10; i++) {
          final rr = i.isEven ? r : r * 0.45;
          final a = -math.pi / 2 + i * math.pi / 5;
          final pt = c + Offset(math.cos(a) * rr, math.sin(a) * rr);
          if (i == 0) {
            p.moveTo(pt.dx, pt.dy);
          } else {
            p.lineTo(pt.dx, pt.dy);
          }
        }
        return p..close();
      case 'line':
        // everything above a line through the centre
        return Path()
          ..addRect(Rect.fromLTRB(-s.width, -s.height, s.width * 2, c.dy));
      case 'film':
        return Path()..addRect(
          Rect.fromLTRB(-s.width, c.dy - r * 0.5, s.width * 2, c.dy + r * 0.5),
        );
    }
    return Path()..addOval(Rect.fromCircle(center: c, radius: r));
  }
}

double _r(double v) => double.parse(v.toStringAsFixed(3));

// ------------------------------------------------------------------ chroma key

/// Removes one colour (a green screen) from a layer (Edit > Chroma key).
class ChromaKey {
  const ChromaKey({
    this.color = 0xFF00FF00,
    this.strength = 0.5,
    this.soft = 0.3,
  });

  /// The colour that becomes see-through (ARGB).
  final int color;

  /// How much around that colour is removed (0..1).
  final double strength;

  /// How soft the edge between kept and removed is (0..1).
  final double soft;

  ChromaKey copyWith({int? color, double? strength, double? soft}) => ChromaKey(
    color: color ?? this.color,
    strength: strength ?? this.strength,
    soft: soft ?? this.soft,
  );

  Map<String, Object> toMap() => {'c': color, 's': _r(strength), 'f': _r(soft)};

  static ChromaKey? fromMap(Object? v) {
    if (v is! Map || v['c'] is! int) return null;
    double d(Object? x, double f) =>
        (x is num ? x.toDouble() : f).clamp(0.0, 1.0);
    return ChromaKey(
      color: v['c'] as int,
      strength: d(v['s'], 0.5),
      soft: d(v['f'], 0.3),
    );
  }

  /// A colour matrix that keeps the picture and turns the key colour see-through.
  /// Alpha = 1 - (how much a pixel leans towards the key colour - threshold) / softness.
  List<double> get matrix {
    final kr = ((color >> 16) & 0xFF) / 255;
    final kg = ((color >> 8) & 0xFF) / 255;
    final kb = (color & 0xFF) / 255;
    final mean = (kr + kg + kb) / 3;
    final dr = kr - mean, dg = kg - mean, db = kb - mean;
    final len2 = dr * dr + dg * dg + db * db;
    // q = w . rgb + q0 is 1 for the key colour and about 0 for everything else
    double wr, wg, wb, q0;
    if (len2 < 0.005) {
      // black, white or grey: by brightness
      if (mean >= 0.5) {
        wr = wg = wb = 1 / 3; // white: q = brightness
        q0 = 0;
      } else {
        wr = wg = wb = -1 / 3;
        q0 = 1;
      }
    } else {
      wr = dr / len2;
      wg = dg / len2;
      wb = db / len2;
      q0 = 0;
    }
    final t = 1 - strength.clamp(0.0, 1.0) * 0.9; // q above t is removed
    final sf = 0.05 + soft.clamp(0.0, 1.0) * 0.6; // over this much
    // alpha = 1 - (q - t) / sf, written for 0..255 colour values
    return [
      1, 0, 0, 0, 0, //
      0, 1, 0, 0, 0, //
      0, 0, 1, 0, 0, //
      -wr / sf, -wg / sf, -wb / sf, 0, 255 * (1 + (t - q0) / sf),
    ];
  }
}

// ---------------------------------------------------------------------- layers

/// Blend modes offered for a layer and their names.
const Map<String, (String, BlendMode)> kBlendModes = {
  'normal': ('Normal', BlendMode.srcOver),
  'multiply': ('Multiply', BlendMode.multiply),
  'screen': ('Screen', BlendMode.screen),
  'overlay': ('Overlay', BlendMode.overlay),
  'darken': ('Darken', BlendMode.darken),
  'lighten': ('Lighten', BlendMode.lighten),
  'add': ('Add', BlendMode.plus),
  'dodge': ('Color dodge', BlendMode.colorDodge),
  'burn': ('Color burn', BlendMode.colorBurn),
  'hard': ('Hard light', BlendMode.hardLight),
  'soft': ('Soft light', BlendMode.softLight),
  'difference': ('Difference', BlendMode.difference),
  'exclusion': ('Exclusion', BlendMode.exclusion),
  'hue': ('Hue', BlendMode.hue),
  'color': ('Color', BlendMode.color),
  'luminosity': ('Luminosity', BlendMode.luminosity),
};

/// A photo or video placed over the clip (Edit > Overlay), with blend, chroma key, mask
/// and animation. Like texts it is drawn while the clip plays; the clip file is untouched.
class MediaLayer {
  const MediaLayer({
    required this.ref,
    this.video = false,
    this.aspect = 1,
    this.dx = 0.5,
    this.dy = 0.5,
    this.scale = 0.6,
    this.turns = 0,
    this.opacity = 1,
    this.blend = 'normal',
    this.chroma,
    this.mask,
    this.anim,
    this.from = 0,
    this.to = -1,
  });

  /// `m:<key>` once uploaded; a file path on the phone before that.
  final String ref;
  final bool video;

  /// Width / height of the photo or video.
  final double aspect;

  /// Centre (parts of the clip's width / height), width as a part of the clip's width.
  final double dx;
  final double dy;
  final double scale;

  /// Turn, in whole turns (0.25 = 90°).
  final double turns;
  final double opacity;

  /// Key of [kBlendModes].
  final String blend;
  final ChromaKey? chroma;
  final LayerMask? mask;
  final MotionAnim? anim;

  /// Seconds of the clip in which it is shown ([to] < 0 = until the end).
  final double from;
  final double to;

  bool get isLocal => !ref.startsWith('m:') && !ref.startsWith('http');
  bool visibleAt(double sec) => sec >= from - 0.001 && (to < 0 || sec <= to);
  BlendMode get blendMode => (kBlendModes[blend] ?? kBlendModes['normal']!).$2;

  MediaLayer copyWith({
    String? ref,
    double? dx,
    double? dy,
    double? scale,
    double? turns,
    double? opacity,
    String? blend,
    ChromaKey? chroma,
    bool clearChroma = false,
    LayerMask? mask,
    bool clearMask = false,
    MotionAnim? anim,
    bool clearAnim = false,
    double? from,
    double? to,
  }) => MediaLayer(
    ref: ref ?? this.ref,
    video: video,
    aspect: aspect,
    dx: dx ?? this.dx,
    dy: dy ?? this.dy,
    scale: scale ?? this.scale,
    turns: turns ?? this.turns,
    opacity: opacity ?? this.opacity,
    blend: blend ?? this.blend,
    chroma: clearChroma ? null : (chroma ?? this.chroma),
    mask: clearMask ? null : (mask ?? this.mask),
    anim: clearAnim ? null : (anim ?? this.anim),
    from: from ?? this.from,
    to: to ?? this.to,
  );

  Map<String, Object> toMap() => {
    'u': ref,
    if (video) 'v': true,
    'a': _r(aspect),
    'x': _r(dx),
    'y': _r(dy),
    'z': _r(scale),
    if (turns != 0) 't': _r(turns),
    if (opacity < 1) 'o': _r(opacity),
    if (blend != 'normal') 'b': blend,
    if (chroma != null) 'k': chroma!.toMap(),
    if (mask != null) 'm': mask!.toMap(),
    if (anim != null && !anim!.isEmpty) 'n': anim!.toMap(),
    if (from > 0) 'f': _r(from),
    if (to >= 0) 'e': _r(to),
  };

  static MediaLayer? fromMap(Object? v) {
    if (v is! Map || v['u'] is! String || (v['u'] as String).isEmpty) {
      return null;
    }
    double d(Object? x, double f) => x is num ? x.toDouble() : f;
    final blend = v['b'] is String && kBlendModes.containsKey(v['b'])
        ? v['b'] as String
        : 'normal';
    return MediaLayer(
      ref: v['u'] as String,
      video: v['v'] == true,
      aspect: d(v['a'], 1).clamp(0.1, 10.0),
      dx: d(v['x'], 0.5).clamp(-0.5, 1.5),
      dy: d(v['y'], 0.5).clamp(-0.5, 1.5),
      scale: d(v['z'], 0.6).clamp(0.05, 4.0),
      turns: d(v['t'], 0),
      opacity: d(v['o'], 1).clamp(0.0, 1.0),
      blend: blend,
      chroma: ChromaKey.fromMap(v['k']),
      mask: LayerMask.fromMap(v['m']),
      anim: MotionAnim.fromMap(v['n']),
      from: d(v['f'], 0),
      to: d(v['e'], -1),
    );
  }
}

// ---------------------------------------------------------------------- finish

/// What is shown on top of a video when people watch it: texts, stickers, layers, the mask
/// and the colour look.
class MediaFinish {
  const MediaFinish({
    this.overlays = const [],
    this.look,
    this.layers = const [],
    this.mask,
  });

  static const MediaFinish none = MediaFinish();

  final List<StoryOverlay> overlays;
  final VideoLook? look;
  final List<MediaLayer> layers;

  /// Mask of the clip itself.
  final LayerMask? mask;

  bool get isEmpty =>
      overlays.isEmpty &&
      (look == null || look!.isEmpty) &&
      layers.isEmpty &&
      mask == null;

  /// Something moves by itself (needs a smooth clock while playing).
  bool get animated =>
      layers.isNotEmpty ||
      overlays.any((o) => o.anim != null && !o.anim!.isEmpty);

  Map<String, Object> toMap() => {
    if (overlays.isNotEmpty) 'ov': [for (final o in overlays) o.toMap()],
    if (look != null && !look!.isEmpty) 'lk': look!.toMap(),
    if (layers.isNotEmpty) 'ly': [for (final l in layers) l.toMap()],
    if (mask != null) 'mk': mask!.toMap(),
  };

  static MediaFinish? fromMap(Object? v) {
    if (v is! Map) return null;
    final ov = v['ov'] is List
        ? [for (final e in v['ov'] as List) ?StoryOverlay.fromMap(e)]
        : const <StoryOverlay>[];
    final ly = v['ly'] is List
        ? [for (final e in v['ly'] as List) ?MediaLayer.fromMap(e)]
        : const <MediaLayer>[];
    final f = MediaFinish(
      overlays: ov,
      look: VideoLook.fromMap(v['lk']),
      layers: ly,
      mask: LayerMask.fromMap(v['mk']),
    );
    return f.isEmpty ? null : f;
  }

  MediaFinish copyWith({
    List<StoryOverlay>? overlays,
    List<MediaLayer>? layers,
  }) => MediaFinish(
    overlays: overlays ?? this.overlays,
    look: look,
    layers: layers ?? this.layers,
    mask: mask,
  );

  /// Times in the editor are seconds of the original video. The uploaded clip keeps only
  /// [parts] (in that order, joined) and plays at [speed]: every start and end time is moved
  /// to where it lands in the uploaded clip. Items that fall completely into a removed part
  /// are dropped.
  MediaFinish retimed(List<(int, int)> parts, double speed) {
    if (parts.isEmpty) return this;
    final sp = speed <= 0 ? 1.0 : speed;
    final total = parts.fold<int>(0, (a, p) => a + p.$2 - p.$1) / sp;
    (double, double)? span(double from, double to) {
      final end = to < 0 ? double.infinity : to;
      double? a, b;
      var acc = 0.0;
      for (final p in parts) {
        final s = math.max(from, p.$1.toDouble());
        final e = math.min(end, p.$2.toDouble());
        if (e > s) {
          a ??= acc + (s - p.$1);
          b = acc + (e - p.$1);
        }
        acc += p.$2 - p.$1;
      }
      if (a == null || b == null) return null;
      final na = a / sp;
      final nb = b / sp;
      return (na < 0.01 ? 0 : na, (to < 0 || nb >= total - 0.01) ? -1 : nb);
    }

    final ov = <StoryOverlay>[];
    for (final o in overlays) {
      if (o.isAlways) {
        ov.add(o);
        continue;
      }
      final t = span(o.from, o.to);
      if (t != null) ov.add(o.copyWith(from: t.$1, to: t.$2));
    }
    final ly = <MediaLayer>[];
    for (final l in layers) {
      if (l.from <= 0 && l.to < 0) {
        ly.add(l);
        continue;
      }
      final t = span(l.from, l.to);
      if (t != null) ly.add(l.copyWith(from: t.$1, to: t.$2));
    }
    return copyWith(overlays: ov, layers: ly);
  }
}

/// The colour look as a filter for a playing video.
ColorFilter lookFilter(VideoLook look) => ColorFilter.matrix(look.matrix);
