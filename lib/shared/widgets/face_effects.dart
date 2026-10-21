import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import '../models/post.dart';
import 'smooth_clock.dart';

/// v0.0.1 effects: one face found by Google ML Kit. All numbers are 0..1
/// of the picture: (lx, ly) / (rx, ry) = the eyes, l t r b = the face box.
@immutable
class FaceBox {
  const FaceBox({
    required this.lx,
    required this.ly,
    required this.rx,
    required this.ry,
    required this.l,
    required this.t,
    required this.r,
    required this.b,
  });

  final double lx, ly, rx, ry, l, t, r, b;

  static double _d(Object? v) => v is num && v.isFinite ? v.toDouble() : 0;

  static FaceBox? fromMap(Object? v) {
    if (v is! Map) return null;
    final f = FaceBox(
      lx: _d(v['lx']),
      ly: _d(v['ly']),
      rx: _d(v['rx']),
      ry: _d(v['ry']),
      l: _d(v['l']),
      t: _d(v['t']),
      r: _d(v['r']),
      b: _d(v['b']),
    );
    return f.r > f.l && f.b > f.t ? f : null;
  }

  List<double> get values => [lx, ly, rx, ry, l, t, r, b];

  static FaceBox fromValues(List<double> v) => FaceBox(
    lx: v[0],
    ly: v[1],
    rx: v[2],
    ry: v[3],
    l: v[4],
    t: v[5],
    r: v[6],
    b: v[7],
  );

  static FaceBox lerp(FaceBox a, FaceBox b, double k) {
    final va = a.values, vb = b.values;
    return fromValues([
      for (var i = 0; i < 8; i++) va[i] + (vb[i] - va[i]) * k,
    ]);
  }

  /// Left-right swapped (selfie mirror).
  FaceBox mirrored() => FaceBox(
    lx: 1 - lx,
    ly: ly,
    rx: 1 - rx,
    ry: ry,
    l: 1 - r,
    t: t,
    r: 1 - l,
    b: b,
  );

  /// Numbers of a picture [src] big, shown with BoxFit.cover in a box
  /// [dst] big -> numbers of that box.
  FaceBox coverInto(Size src, Size dst) {
    if (src.isEmpty || dst.isEmpty) return this;
    final s = math.max(dst.width / src.width, dst.height / src.height);
    final dx = (dst.width - src.width * s) / 2;
    final dy = (dst.height - src.height * s) / 2;
    double x(double v) => (v * src.width * s + dx) / dst.width;
    double y(double v) => (v * src.height * s + dy) / dst.height;
    return FaceBox(
      lx: x(lx),
      ly: y(ly),
      rx: x(rx),
      ry: y(ry),
      l: x(l),
      t: y(t),
      r: x(r),
      b: y(b),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FaceBox && _listEq(other.values, values);

  @override
  int get hashCode => Object.hashAll(values.map((v) => (v * 1000).round()));

  static bool _listEq(List<double> a, List<double> b) {
    for (var i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > 0.0005) return false;
    }
    return true;
  }
}

/// Where the face is over time in a filmed video:
/// "v1;0,lx,ly,rx,ry,l,t,r,b;200;400,..." (a time without numbers = no face).
class FaceTrack {
  const FaceTrack(this.times, this.faces);

  final List<int> times;
  final List<FaceBox?> faces;

  bool get hasFace => faces.any((f) => f != null);

  static FaceTrack? parse(String s) {
    if (!s.startsWith('v1')) return null;
    final times = <int>[];
    final faces = <FaceBox?>[];
    var last = -1;
    for (final part in s.split(';').skip(1)) {
      final bits = part.split(',');
      final t = int.tryParse(bits.first);
      if (t == null || t < last) continue;
      FaceBox? f;
      if (bits.length == 9) {
        final v = [for (final b in bits.skip(1)) double.tryParse(b)];
        if (!v.contains(null)) {
          f = FaceBox.fromValues(v.whereType<double>().toList());
          if (!(f.r > f.l && f.b > f.t)) f = null;
        }
      }
      last = t;
      times.add(t);
      faces.add(f);
    }
    return times.isEmpty ? null : FaceTrack(times, faces);
  }

  String encode() {
    final sb = StringBuffer('v1');
    for (var i = 0; i < times.length; i++) {
      sb.write(';${times[i]}');
      final f = faces[i];
      if (f != null) {
        for (final v in f.values) {
          sb.write(',${v.toStringAsFixed(3)}');
        }
      }
    }
    return sb.toString();
  }

  /// The face at [ms] (smooth between two samples), null = no face.
  FaceBox? at(int ms) {
    if (times.isEmpty) return null;
    if (ms <= times.first) return faces.first;
    if (ms >= times.last) return faces.last;
    var lo = 0, hi = times.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (times[mid] <= ms) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = faces[lo], b = faces[hi];
    final span = times[hi] - times[lo];
    final k = span <= 0 ? 0.0 : (ms - times[lo]) / span;
    if (a != null && b != null) {
      // a long gap = the face may have moved a lot: no sliding across
      if (span > 1500) return k < 0.5 ? a : b;
      return FaceBox.lerp(a, b, k);
    }
    return k < 0.5 ? a : b;
  }
}

/// One face effect (drawn, no pictures: nothing to download).
class FaceEffect {
  const FaceEffect(this.id, this.name);
  final String id;
  final String name;
}

const List<FaceEffect> kFaceEffects = [
  FaceEffect('sunglasses', 'Shades'),
  FaceEffect('hearts', 'Hearts'),
  FaceEffect('round', 'Round'),
  FaceEffect('stars', 'Stars'),
  FaceEffect('hero', 'Hero mask'),
  FaceEffect('crown', 'Crown'),
  FaceEffect('dog', 'Puppy'),
  FaceEffect('cat', 'Kitty'),
  FaceEffect('bunny', 'Bunny'),
  FaceEffect('devil', 'Devil'),
  FaceEffect('halo', 'Angel'),
  FaceEffect('party', 'Party'),
  FaceEffect('flowers', 'Flowers'),
  FaceEffect('mustache', 'Mustache'),
  FaceEffect('nerd', 'Nerd'),
  FaceEffect('clown', 'Clown'),
  FaceEffect('pig', 'Piggy'),
  FaceEffect('bear', 'Teddy'),
  FaceEffect('beard', 'Beard'),
  FaceEffect('pirate', 'Pirate'),
  FaceEffect('headphones', 'Headphones'),
  FaceEffect('cowboy', 'Cowboy'),
  FaceEffect('santa', 'Santa'),
  FaceEffect('ninja', 'Ninja'),
  FaceEffect('visor', 'Cyber'),
  FaceEffect('freckles', 'Freckles'),
];

bool isFaceEffect(String id) => kFaceEffects.any((e) => e.id == id);

/// A pretend face for the effect buttons.
const FaceBox kSampleFace = FaceBox(
  lx: 0.64,
  ly: 0.52,
  rx: 0.36,
  ry: 0.52,
  l: 0.22,
  t: 0.3,
  r: 0.78,
  b: 0.9,
);

/// Draws [effect] on [faces] (numbers 0..1 of [size]).
void paintFaceEffects(
  Canvas canvas,
  Size size,
  String effect,
  Iterable<FaceBox> faces,
) {
  for (final f in faces) {
    _paintOne(canvas, size, effect, f);
  }
}

void _paintOne(Canvas canvas, Size size, String effect, FaceBox f) {
  final w = size.width, h = size.height;
  final e1 = Offset(f.lx * w, f.ly * h), e2 = Offset(f.rx * w, f.ry * h);
  final a = e1.dx <= e2.dx ? e1 : e2; // eye on the left of the picture
  final b = e1.dx <= e2.dx ? e2 : e1;
  final d = (b - a).distance;
  if (d < 3 || !d.isFinite) return;
  final angle = math.atan2(b.dy - a.dy, b.dx - a.dx);
  final c = (a + b) / 2;
  final box = Rect.fromLTRB(f.l * w, f.t * h, f.r * w, f.b * h);
  final cosA = math.cos(angle).abs().clamp(0.5, 1.0);
  // in "face units": eye to eye = 100
  final u = d / 100;
  final up = (((c.dy - box.top) / cosA) / u).clamp(90.0, 300.0);
  final down = (((box.bottom - c.dy) / cosA) / u).clamp(110.0, 320.0);
  final half = ((box.width / 2) / u).clamp(80.0, 200.0);
  canvas.save();
  canvas.translate(c.dx, c.dy);
  canvas.rotate(angle);
  canvas.scale(u);
  final g = _Face(canvas, top: -up, chin: down, half: half);
  switch (effect) {
    case 'sunglasses':
      g.sunglasses();
    case 'hearts':
      g.hearts();
    case 'round':
      g.round();
    case 'stars':
      g.stars();
    case 'hero':
      g.hero();
    case 'crown':
      g.crown();
    case 'dog':
      g.dog();
    case 'cat':
      g.cat();
    case 'bunny':
      g.bunny();
    case 'devil':
      g.devil();
    case 'halo':
      g.halo();
    case 'party':
      g.party();
    case 'flowers':
      g.flowers();
    case 'mustache':
      g.mustache();
    case 'nerd':
      g.nerd();
    case 'clown':
      g.clown();
    case 'pig':
      g.pig();
    case 'bear':
      g.bear();
    case 'beard':
      g.beard();
    case 'pirate':
      g.pirate();
    case 'headphones':
      g.headphones();
    case 'cowboy':
      g.cowboy();
    case 'santa':
      g.santa();
    case 'ninja':
      g.ninja();
    case 'visor':
      g.visor();
    case 'freckles':
      g.freckles();
  }
  canvas.restore();
}

/// Drawing in face units: eyes at (-50, 0) and (50, 0), y goes down the
/// face, [top] = top of the head, [chin], [half] = half the face width.
class _Face {
  _Face(this.c, {required this.top, required this.chin, required this.half});

  final Canvas c;
  final double top;
  final double chin;
  final double half;

  Paint _fill(Color color) => Paint()
    ..color = color
    ..isAntiAlias = true;

  Paint _line(Color color, double width) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  void _arms(Color color, double y) {
    final p = _line(color, 6);
    c.drawLine(Offset(-92, y), Offset(-half, y - 4), p);
    c.drawLine(Offset(92, y), Offset(half, y - 4), p);
  }

  void _bridge(Color color) {
    final path = Path()
      ..moveTo(-12, -4)
      ..quadraticBezierTo(0, -14, 12, -4);
    c.drawPath(path, _line(color, 6));
  }

  void _shine(Offset at) {
    final p = _line(Colors.white.withValues(alpha: 0.35), 4);
    c.drawLine(at + const Offset(-14, -6), at + const Offset(-4, -16), p);
  }

  void sunglasses() {
    _arms(const Color(0xFF111111), -6);
    for (final x in [-50.0, 50.0]) {
      final r = RRect.fromRectAndCorners(
        Rect.fromCenter(center: Offset(x, 4), width: 86, height: 62),
        topLeft: const Radius.circular(14),
        topRight: const Radius.circular(14),
        bottomLeft: const Radius.circular(30),
        bottomRight: const Radius.circular(30),
      );
      c.drawRRect(
        r,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xF0101010), Color(0xE0303848)],
          ).createShader(r.outerRect),
      );
      c.drawRRect(r, _line(const Color(0xFF050505), 5));
      _shine(Offset(x, 0));
    }
    _bridge(const Color(0xFF111111));
  }

  Path _heart(Offset o, double s) {
    final p = Path();
    p.moveTo(o.dx, o.dy + s * 0.42);
    p.cubicTo(
      o.dx - s * 0.62,
      o.dy,
      o.dx - s * 0.5,
      o.dy - s * 0.5,
      o.dx,
      o.dy - s * 0.22,
    );
    p.cubicTo(
      o.dx + s * 0.5,
      o.dy - s * 0.5,
      o.dx + s * 0.62,
      o.dy,
      o.dx,
      o.dy + s * 0.42,
    );
    p.close();
    return p;
  }

  void hearts() {
    _arms(const Color(0xFFFF4F7B), -6);
    for (final x in [-50.0, 50.0]) {
      final p = _heart(Offset(x, 4), 96);
      c.drawPath(p, _fill(const Color(0xD9FF2D55)));
      c.drawPath(p, _line(const Color(0xFFFF9EB5), 4));
      _shine(Offset(x, -2));
    }
    _bridge(const Color(0xFFFF4F7B));
  }

  void round() {
    const gold = Color(0xFFD9A93B);
    _arms(gold, -4);
    for (final x in [-50.0, 50.0]) {
      c.drawCircle(Offset(x, 2), 37, _fill(const Color(0x22FFFFFF)));
      c.drawCircle(Offset(x, 2), 37, _line(gold, 6));
      _shine(Offset(x, 2));
    }
    _bridge(gold);
  }

  Path _star(Offset o, double r) {
    final p = Path();
    for (var i = 0; i < 10; i++) {
      final rr = i.isEven ? r : r * 0.48;
      final a = -math.pi / 2 + i * math.pi / 5;
      final pt = o + Offset(math.cos(a) * rr, math.sin(a) * rr);
      i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
    }
    return p..close();
  }

  void stars() {
    _arms(const Color(0xFFFF9F0A), -6);
    for (final x in [-50.0, 50.0]) {
      final p = _star(Offset(x, 4), 52);
      c.drawPath(p, _fill(const Color(0xE6FFD60A)));
      c.drawPath(p, _line(const Color(0xFFFF9F0A), 4));
    }
    _bridge(const Color(0xFFFF9F0A));
  }

  void hero() {
    final w = half * 0.95;
    final band = Path()
      ..moveTo(-w, -10)
      ..quadraticBezierTo(-w * 0.6, -48, 0, -26)
      ..quadraticBezierTo(w * 0.6, -48, w, -10)
      ..quadraticBezierTo(w * 0.85, 34, 18, 30)
      ..quadraticBezierTo(0, 22, -18, 30)
      ..quadraticBezierTo(-w * 0.85, 34, -w, -10)
      ..close();
    final holes = Path()
      ..addOval(
        Rect.fromCenter(center: const Offset(-48, 0), width: 50, height: 32),
      )
      ..addOval(
        Rect.fromCenter(center: const Offset(48, 0), width: 50, height: 32),
      );
    final mask = Path.combine(PathOperation.difference, band, holes);
    c.drawPath(mask, _fill(const Color(0xF2141414)));
    c.drawPath(mask, _line(const Color(0xFF2E2E2E), 2));
  }

  void crown() {
    final by = top + 18;
    final w = half * 1.25;
    final p = Path()..moveTo(-w / 2, by);
    const peaks = 5;
    for (var i = 0; i <= peaks * 2; i++) {
      final x = -w / 2 + w * i / (peaks * 2);
      final y = i.isEven ? by - 82 : by - 36;
      p.lineTo(x, i == 0 || i == peaks * 2 ? by - 82 : y);
    }
    p
      ..lineTo(w / 2, by)
      ..close();
    final rect = Rect.fromLTRB(-w / 2, by - 90, w / 2, by);
    c.drawPath(
      p,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFE27A), Color(0xFFE0A800)],
        ).createShader(rect),
    );
    c.drawPath(p, _line(const Color(0xFFB07D00), 3));
    c.drawRect(
      Rect.fromLTRB(-w / 2, by - 18, w / 2, by),
      _fill(const Color(0xFFC99400)),
    );
    const gems = [Color(0xFFFF2D55), Color(0xFF0A84FF), Color(0xFF30D158)];
    for (var i = 0; i <= peaks; i++) {
      final x = -w / 2 + w * i / peaks;
      c.drawCircle(Offset(x, by - 84), 7, _fill(gems[i % 3]));
    }
    for (var i = 0; i < 3; i++) {
      c.drawCircle(
        Offset(-w / 4 + i * w / 4, by - 9),
        6,
        _fill(gems[(i + 1) % 3]),
      );
    }
  }

  void _nose(Color color, double y, double w, double h) {
    final r = Rect.fromCenter(center: Offset(0, y), width: w, height: h);
    c.drawOval(r, _fill(color));
    c.drawOval(
      Rect.fromCenter(
        center: Offset(-w * 0.18, y - h * 0.2),
        width: w * 0.3,
        height: h * 0.25,
      ),
      _fill(Colors.white.withValues(alpha: 0.45)),
    );
  }

  void dog() {
    const brown = Color(0xFF8B5A2B), dark = Color(0xFF5E3A17);
    for (final s in [-1.0, 1.0]) {
      c.save();
      c.translate(s * half * 0.92, top + 30);
      c.rotate(s * 0.35);
      final ear = Path()
        ..moveTo(0, -20)
        ..cubicTo(s * 70, -10, s * 70, 120, s * 18, 140)
        ..cubicTo(s * -10, 120, s * -20, 30, 0, -20)
        ..close();
      c.drawPath(ear, _fill(brown));
      c.drawPath(ear, _line(dark, 4));
      c.restore();
    }
    _nose(const Color(0xFF151515), 66, 50, 34);
  }

  void cat() {
    for (final s in [-1.0, 1.0]) {
      final x = s * half * 0.62;
      final outer = Path()
        ..moveTo(x - 38, top + 26)
        ..lineTo(x + s * 14, top - 64)
        ..lineTo(x + 38, top + 26)
        ..close();
      final inner = Path()
        ..moveTo(x - 20, top + 18)
        ..lineTo(x + s * 10, top - 36)
        ..lineTo(x + 20, top + 18)
        ..close();
      c.drawPath(outer, _fill(const Color(0xFF2B2B2B)));
      c.drawPath(inner, _fill(const Color(0xFFFF9EB5)));
    }
    final nose = Path()
      ..moveTo(-12, 56)
      ..lineTo(12, 56)
      ..lineTo(0, 70)
      ..close();
    c.drawPath(nose, _fill(const Color(0xFFFF7FA0)));
    final wh = _line(Colors.white.withValues(alpha: 0.9), 2.5);
    for (final s in [-1.0, 1.0]) {
      for (var i = 0; i < 3; i++) {
        c.drawLine(
          Offset(s * 26, 74 + i * 7.0),
          Offset(s * 120, 58 + i * 16.0),
          wh,
        );
      }
    }
  }

  void bunny() {
    for (final s in [-1.0, 1.0]) {
      c.save();
      c.translate(s * 38, top + 10);
      c.rotate(s * 0.16);
      final outer = Rect.fromCenter(
        center: const Offset(0, -80),
        width: 46,
        height: 168,
      );
      final inner = Rect.fromCenter(
        center: const Offset(0, -76),
        width: 22,
        height: 130,
      );
      c.drawOval(outer, _fill(Colors.white));
      c.drawOval(outer, _line(const Color(0xFFE5E5EA), 3));
      c.drawOval(inner, _fill(const Color(0xFFFFB3C7)));
      c.restore();
    }
    _nose(const Color(0xFFFF7FA0), 60, 26, 18);
  }

  void devil() {
    for (final s in [-1.0, 1.0]) {
      final x = s * half * 0.5;
      final horn = Path()
        ..moveTo(x - s * 26, top + 22)
        ..quadraticBezierTo(x + s * 4, top - 30, x + s * 40, top - 66)
        ..quadraticBezierTo(x + s * 22, top - 16, x + s * 28, top + 22)
        ..close();
      final r = Rect.fromLTRB(x - 30, top - 70, x + 44, top + 24);
      c.drawPath(
        horn,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xFFB00020), Color(0xFFFF453A)],
          ).createShader(r),
      );
    }
  }

  void halo() {
    final r = Rect.fromCenter(
      center: Offset(0, top - 34),
      width: half * 1.3,
      height: 36,
    );
    c.drawOval(
      r,
      _line(const Color(0x99FFE27A), 16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    c.drawOval(r, _line(const Color(0xFFFFE27A), 7));
  }

  void party() {
    c.save();
    c.translate(half * 0.25, top + 16);
    c.rotate(0.28);
    const base = 64.0, height = 150.0;
    final cone = Path()
      ..moveTo(-base, 0)
      ..lineTo(0, -height)
      ..lineTo(base, 0)
      ..close();
    c.drawPath(cone, _fill(const Color(0xFF5E5CE6)));
    c.save();
    c.clipPath(cone);
    final stripe = _line(const Color(0xFFFFD60A), 14);
    for (var i = 1; i < 5; i++) {
      final y = -height * i / 5;
      c.drawLine(Offset(-base, y + 26), Offset(base, y - 26), stripe);
    }
    c.restore();
    c.drawCircle(const Offset(0, -height), 16, _fill(const Color(0xFFFF375F)));
    c.restore();
  }

  void flowers() {
    const colors = [
      Color(0xFFFF6B9D),
      Color(0xFFFFD60A),
      Color(0xFFBF5AF2),
      Color(0xFFFF9F0A),
      Color(0xFF64D2FF),
    ];
    const n = 7;
    for (var i = 0; i < n; i++) {
      final k = i / (n - 1);
      final x = -half * 1.05 + half * 2.1 * k;
      final y = top + 18 - math.sin(k * math.pi) * 24;
      if (i < n - 1) {
        c.drawOval(
          Rect.fromCenter(
            center: Offset(x + half * 0.17, y + 4),
            width: 30,
            height: 14,
          ),
          _fill(const Color(0xFF34C759)),
        );
      }
      final col = colors[i % colors.length];
      for (var p = 0; p < 5; p++) {
        final a = p * 2 * math.pi / 5;
        c.drawCircle(
          Offset(x + math.cos(a) * 13, y + math.sin(a) * 13),
          11,
          _fill(col),
        );
      }
      c.drawCircle(Offset(x, y), 8, _fill(const Color(0xFFFFF3B0)));
    }
  }

  void mustache() {
    final y = 86.0;
    final p = Path()..moveTo(0, y - 6);
    for (final s in [-1.0, 1.0]) {
      p
        ..moveTo(0, y - 6)
        ..cubicTo(s * 30, y - 22, s * 62, y - 10, s * 76, y - 22)
        ..cubicTo(s * 86, y - 30, s * 92, y - 14, s * 80, y - 6)
        ..cubicTo(s * 60, y + 14, s * 24, y + 8, 0, y + 2)
        ..close();
    }
    c.drawPath(p, _fill(const Color(0xFF2A1A0E)));
  }

  void nerd() {
    const frame = Color(0xFF151515);
    _arms(frame, -8);
    for (final x in [-50.0, 50.0]) {
      final r = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x, 2), width: 82, height: 62),
        const Radius.circular(10),
      );
      c.drawRRect(r, _fill(const Color(0x1AFFFFFF)));
      c.drawRRect(r, _line(frame, 10));
      _shine(Offset(x, 0));
    }
    _bridge(frame);
    // white tape on the middle
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: const Offset(0, -6), width: 22, height: 22),
        const Radius.circular(3),
      ),
      _fill(const Color(0xFFF2F2F2)),
    );
  }

  void _cheeks(Color color, double alpha) {
    for (final s in [-1.0, 1.0]) {
      c.drawOval(
        Rect.fromCenter(center: Offset(s * 62, 58), width: 48, height: 30),
        _fill(color.withValues(alpha: alpha))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
      );
    }
  }

  void clown() {
    _cheeks(const Color(0xFFFF3B30), 0.45);
    const nose = Offset(0, 58);
    c.drawCircle(
      nose,
      27,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.35, -0.4),
          colors: [Color(0xFFFF8A80), Color(0xFFE00000), Color(0xFF9B0000)],
          stops: [0, 0.55, 1],
        ).createShader(Rect.fromCircle(center: nose, radius: 27)),
    );
    c.drawCircle(
      nose + const Offset(-9, -10),
      6,
      _fill(Colors.white.withValues(alpha: 0.7)),
    );
  }

  void pig() {
    _cheeks(const Color(0xFFFF8FAB), 0.35);
    final r = Rect.fromCenter(
      center: const Offset(0, 60),
      width: 62,
      height: 44,
    );
    c.drawOval(r, _fill(const Color(0xFFFFA3BC)));
    c.drawOval(r, _line(const Color(0xFFE87A98), 4));
    for (final s in [-1.0, 1.0]) {
      c.drawOval(
        Rect.fromCenter(center: Offset(s * 12, 61), width: 11, height: 18),
        _fill(const Color(0xFF9C3A57)),
      );
    }
    // little pig ears
    for (final s in [-1.0, 1.0]) {
      final x = s * half * 0.62;
      final ear = Path()
        ..moveTo(x - 30, top + 30)
        ..quadraticBezierTo(x + s * 30, top - 50, x + 34, top + 28)
        ..close();
      c.drawPath(ear, _fill(const Color(0xFFFFA3BC)));
      c.drawPath(ear, _line(const Color(0xFFE87A98), 4));
    }
  }

  void bear() {
    const fur = Color(0xFF8D5B34), inner = Color(0xFFD9A577);
    for (final s in [-1.0, 1.0]) {
      final o = Offset(s * half * 0.72, top + 14);
      c.drawCircle(o, 40, _fill(fur));
      c.drawCircle(o, 22, _fill(inner));
    }
    c.drawOval(
      Rect.fromCenter(center: const Offset(0, 74), width: 92, height: 66),
      _fill(inner.withValues(alpha: 0.9)),
    );
    _nose(const Color(0xFF2B1A10), 58, 40, 28);
    final mouth = Path()
      ..moveTo(0, 72)
      ..lineTo(0, 86)
      ..moveTo(-14, 92)
      ..quadraticBezierTo(0, 100, 14, 92);
    c.drawPath(mouth, _line(const Color(0xFF2B1A10), 4));
  }

  void beard() {
    const hair = Color(0xFF3B2414);
    final w = half * 0.98;
    final b = Path()
      ..moveTo(-w, 40)
      ..quadraticBezierTo(-w * 0.95, chin + 40, 0, chin + 58)
      ..quadraticBezierTo(w * 0.95, chin + 40, w, 40)
      ..quadraticBezierTo(w * 0.7, 120, 34, 108)
      ..quadraticBezierTo(0, 98, -34, 108)
      ..quadraticBezierTo(-w * 0.7, 120, -w, 40)
      ..close();
    final mouth = Path()
      ..addOval(
        Rect.fromCenter(center: const Offset(0, 112), width: 56, height: 24),
      );
    final shape = Path.combine(PathOperation.difference, b, mouth);
    c.drawPath(shape, _fill(hair));
    // a bit of texture
    final t = _line(const Color(0xFF5A3A22), 2.5);
    for (var i = 0; i < 9; i++) {
      final x = -w * 0.7 + w * 1.4 * i / 8;
      c.drawLine(Offset(x, chin - 4), Offset(x * 0.92, chin + 26), t);
    }
    mustache();
  }

  void pirate() {
    // strap
    final strap = Path()
      ..moveTo(-half, -40)
      ..quadraticBezierTo(0, -10, half, 30);
    c.drawPath(strap, _line(const Color(0xFF111111), 7));
    // patch on the right eye of the picture
    final patch = Path()
      ..moveTo(18, -16)
      ..quadraticBezierTo(50, -32, 82, -16)
      ..quadraticBezierTo(90, 34, 50, 40)
      ..quadraticBezierTo(10, 34, 18, -16)
      ..close();
    c.drawPath(patch, _fill(const Color(0xFF0D0D0D)));
    c.drawPath(patch, _line(const Color(0xFF2C2C2C), 3));
    // red bandana
    final by = top + 34;
    final w = half * 1.12;
    final band = Path()
      ..moveTo(-w, by + 20)
      ..quadraticBezierTo(0, top - 70, w, by + 20)
      ..quadraticBezierTo(0, by - 8, -w, by + 20)
      ..close();
    c.drawPath(band, _fill(const Color(0xFFD62828)));
    for (var i = 0; i < 5; i++) {
      c.drawCircle(
        Offset(
          -w * 0.6 + w * 0.3 * i,
          by - 18 - (i == 2 ? 14 : (i == 1 || i == 3 ? 8 : 0)),
        ),
        5,
        _fill(Colors.white),
      );
    }
  }

  void headphones() {
    final band = Rect.fromLTRB(-half * 1.12, top - 34, half * 1.12, top + 200);
    c.drawArc(
      band,
      math.pi * 1.08,
      math.pi * 0.84,
      false,
      _line(const Color(0xFF1C1C1E), 18),
    );
    c.drawArc(
      band,
      math.pi * 1.1,
      math.pi * 0.8,
      false,
      _line(const Color(0xFF3A3A3C), 6),
    );
    for (final s in [-1.0, 1.0]) {
      final cup = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(s * (half + 6), 20),
          width: 50,
          height: 92,
        ),
        const Radius.circular(24),
      );
      c.drawRRect(cup, _fill(const Color(0xFF1C1C1E)));
      c.drawRRect(cup.deflate(9), _fill(const Color(0xFF30D158)));
    }
  }

  void cowboy() {
    final by = top + 26;
    const leather = Color(0xFF9C6B3C);
    // wide brim, curled up at the sides
    final brim = Path()
      ..moveTo(-half * 1.5, by - 34)
      ..quadraticBezierTo(-half * 1.25, by + 4, -half * 0.6, by + 10)
      ..quadraticBezierTo(0, by + 18, half * 0.6, by + 10)
      ..quadraticBezierTo(half * 1.25, by + 4, half * 1.5, by - 34)
      ..quadraticBezierTo(half * 1.2, by - 14, half * 0.6, by - 16)
      ..quadraticBezierTo(0, by - 10, -half * 0.6, by - 16)
      ..quadraticBezierTo(-half * 1.2, by - 14, -half * 1.5, by - 34)
      ..close();
    final crown = Path()
      ..moveTo(-half * 0.66, by - 8)
      ..quadraticBezierTo(-half * 0.78, by - 112, -half * 0.3, by - 116)
      ..quadraticBezierTo(0, by - 94, half * 0.3, by - 116)
      ..quadraticBezierTo(half * 0.78, by - 112, half * 0.66, by - 8)
      ..close();
    c.drawPath(crown, _fill(leather));
    c.drawPath(crown, _line(const Color(0xFF6B4423), 3));
    c.drawRect(
      Rect.fromLTRB(-half * 0.7, by - 36, half * 0.7, by - 18),
      _fill(const Color(0xFF3E2611)),
    );
    c.drawPath(brim, _fill(const Color(0xFF8A5A2E)));
    c.drawPath(brim, _line(const Color(0xFF5E3A17), 3));
  }

  void santa() {
    final by = top + 30;
    final w = half * 1.1;
    final hat = Path()
      ..moveTo(-w, by)
      ..quadraticBezierTo(-w * 0.6, by - 150, w * 0.5, by - 170)
      ..quadraticBezierTo(w * 1.2, by - 160, w * 1.25, by - 70)
      ..quadraticBezierTo(w * 0.9, by - 120, w * 0.6, by - 118)
      ..quadraticBezierTo(w * 0.8, by - 60, w, by)
      ..close();
    c.drawPath(hat, _fill(const Color(0xFFD7263D)));
    final fur = RRect.fromRectAndRadius(
      Rect.fromLTRB(-w - 10, by - 28, w + 10, by + 14),
      const Radius.circular(21),
    );
    c.drawRRect(fur, _fill(Colors.white));
    c.drawCircle(Offset(w * 1.25, by - 64), 22, _fill(Colors.white));
  }

  void ninja() {
    final w = half * 1.02;
    final cover = Path()
      ..moveTo(-w, 34)
      ..quadraticBezierTo(0, 18, w, 34)
      ..quadraticBezierTo(w, chin + 30, 0, chin + 40)
      ..quadraticBezierTo(-w, chin + 30, -w, 34)
      ..close();
    c.drawPath(cover, _fill(const Color(0xFF1B1B1F)));
    final band = Rect.fromLTRB(-w - 6, top + 40, w + 6, top + 74);
    c.drawRect(band, _fill(const Color(0xFFD62828)));
    for (final s in [-1.0, 1.0]) {
      final tail = Path()
        ..moveTo(w + 4, top + 50)
        ..quadraticBezierTo(w + 40, top + 60, w + 70, top + 110 + s * 14)
        ..lineTo(w + 54, top + 114 + s * 14)
        ..quadraticBezierTo(w + 30, top + 74, w + 4, top + 66)
        ..close();
      c.drawPath(tail, _fill(const Color(0xFFB71C1C)));
    }
  }

  void visor() {
    final r = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: const Offset(0, 0),
        width: half * 2.05,
        height: 64,
      ),
      const Radius.circular(32),
    );
    c.drawRRect(
      r,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xE600E5FF), Color(0xE6BF5AF2), Color(0xE6FF2D95)],
        ).createShader(r.outerRect),
    );
    c.drawRRect(
      r,
      _line(const Color(0xFF00E5FF), 4)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    final scan = _line(Colors.white.withValues(alpha: 0.35), 2);
    for (var i = 1; i < 5; i++) {
      final y = -32 + 64 * i / 5;
      c.drawLine(Offset(-half * 0.95, y), Offset(half * 0.95, y), scan);
    }
  }

  void freckles() {
    _cheeks(const Color(0xFFFF6F61), 0.3);
    final dot = _fill(const Color(0xFF8B4A2B).withValues(alpha: 0.75));
    const spots = [
      Offset(-70, 44),
      Offset(-56, 52),
      Offset(-80, 58),
      Offset(-62, 66),
      Offset(-44, 46),
      Offset(-50, 62),
      Offset(70, 44),
      Offset(56, 52),
      Offset(80, 58),
      Offset(62, 66),
      Offset(44, 46),
      Offset(50, 62),
      Offset(-14, 40),
      Offset(12, 42),
      Offset(0, 48),
    ];
    for (final o in spots) {
      c.drawCircle(o, 3.2, dot);
    }
    // sparkles
    final sp = _fill(Colors.white);
    for (final o in const [
      Offset(-110, -40),
      Offset(104, -60),
      Offset(120, 30),
    ]) {
      c.drawPath(_star(o, 12), sp);
    }
  }
}

/// Paints [effect] on [faces] (0..1 of this box).
class FaceFxPainter extends CustomPainter {
  const FaceFxPainter(this.effect, this.faces);
  final String effect;
  final List<FaceBox> faces;

  @override
  void paint(Canvas canvas, Size size) =>
      paintFaceEffects(canvas, size, effect, faces);

  @override
  bool shouldRepaint(FaceFxPainter old) =>
      old.effect != effect || !_same(old.faces, faces);

  static bool _same(List<FaceBox> a, List<FaceBox> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// v0.0.1 effects: the face effect of a playing video. Put it on top of
/// the video, in a box with the video's shape (like VideoOverlayLayer).
/// Moves smoothly (its own clock between the player's updates).
class FaceFxLayer extends StatefulWidget {
  const FaceFxLayer({super.key, required this.fx, required this.controller});

  final FaceFx fx;
  final VideoPlayerController controller;

  @override
  State<FaceFxLayer> createState() => _FaceFxLayerState();
}

class _FaceFxLayerState extends State<FaceFxLayer>
    with SingleTickerProviderStateMixin {
  static final Map<String, FaceTrack?> _cache = {};
  late final Ticker _ticker = createTicker(_tick);
  final SmoothClock _clock = SmoothClock();
  FaceTrack? _track;
  FaceBox? _face;

  @override
  void initState() {
    super.initState();
    _load();
    _ticker.start();
  }

  @override
  void didUpdateWidget(FaceFxLayer old) {
    super.didUpdateWidget(old);
    if (old.fx.track != widget.fx.track) _load();
    if (old.controller != widget.controller) _clock.reset();
  }

  void _load() {
    final t = widget.fx.track;
    if (_cache.length > 40) _cache.clear();
    _track = _cache.putIfAbsent(t, () => FaceTrack.parse(t));
  }

  void _tick(Duration elapsed) {
    final v = widget.controller.value;
    if (!v.isInitialized) return;
    final ms = _clock.position(
      reported: v.position.inMilliseconds,
      playing: v.isPlaying,
      nowMs: elapsed.inMilliseconds,
      speed: v.playbackSpeed,
    );
    final f = _track?.at(ms);
    if (f != _face) setState(() => _face = f);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = _face;
    if (f == null || !isFaceEffect(widget.fx.effect)) {
      return const SizedBox.expand();
    }
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: FaceFxPainter(widget.fx.effect, [f]),
        ),
      ),
    );
  }
}
