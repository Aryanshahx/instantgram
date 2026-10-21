import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../models/post.dart';
import 'bio_font.dart';

/// Text background styles (tap the "A" in the text editor to change).
abstract final class TextBg {
  /// No background (soft shadow).
  static const int none = 0;

  /// Your colour on a black / white box.
  static const int solid = 1;

  /// A box in your colour, the text black / white.
  static const int inverse = 2;

  /// See-through dark box.
  static const int soft = 3;

  static const int count = 4;

  static int clean(Object? v) =>
      v is num && v.toInt() >= 0 && v.toInt() < count ? v.toInt() : none;
}

/// How a text on a photo / video looks (the same in the editor, the
/// saved photo, the cover and when watching).
class TextSpec {
  const TextSpec({
    required this.text,
    this.color = Colors.white,
    this.font = '',
    this.bg = TextBg.none,
    this.align = 0,
    this.outline = false,
    this.glow = false,
    this.spacing = 0,
    this.shadow = 0.15,
  });

  final String text;
  final Color color;

  /// Font id (see BioFont, '' = app font).
  final String font;

  /// [TextBg].
  final int bg;

  /// 0 = middle, 1 = left, 2 = right.
  final int align;
  final bool outline;
  final bool glow;

  /// Space between letters (part of the font size).
  final double spacing;

  /// Soft shadow blur (part of the font size) when there is no box.
  final double shadow;

  TextAlign get textAlign => switch (align) {
    1 => TextAlign.left,
    2 => TextAlign.right,
    _ => TextAlign.center,
  };

  static bool light(Color c) => c.computeLuminance() > 0.5;

  /// A video text / emoji sticker.
  factory TextSpec.ofOverlay(VideoOverlay o) => o.isSticker
      ? TextSpec(text: o.text, shadow: 0)
      : TextSpec(
          text: o.text,
          color: Color(o.color),
          font: o.font,
          bg: o.background ? TextBg.clean(o.bgStyle) : TextBg.none,
          align: o.align,
          outline: o.outline,
          glow: o.glow,
          spacing: o.spacing,
          shadow: 0.25,
        );
}

/// The laid-out text: [size] (with the box) and [paint].
class StyledTextLayout {
  StyledTextLayout(
    this.spec, {
    required this.fontSize,
    required double maxWidth,
  }) {
    final s = spec;
    final fs = fontSize;
    final hasBox = s.bg != TextBg.none;
    padH = hasBox ? fs * 0.42 : (s.outline ? fs * 0.06 : 0.0);
    padV = hasBox ? fs * 0.14 : (s.outline ? fs * 0.06 : 0.0);
    final lightText = TextSpec.light(s.color);
    final Color fill;
    if (s.bg == TextBg.inverse) {
      fill = lightText ? Colors.black : Colors.white;
    } else if (s.glow) {
      fill = Color.lerp(s.color, Colors.white, 0.55)!;
    } else {
      fill = s.color;
    }
    List<Shadow>? shadows;
    if (s.glow) {
      shadows = [
        Shadow(color: s.color, blurRadius: fs * 0.45),
        Shadow(color: s.color, blurRadius: fs * 0.18),
      ];
    } else if (!hasBox && !s.outline && s.shadow > 0) {
      shadows = [Shadow(blurRadius: fs * s.shadow, color: Colors.black54)];
    }
    TextStyle style(Color? color, Paint? fg, List<Shadow>? sh) => TextStyle(
      fontFamily: BioFont.family(s.font, AppTheme.fontFamily),
      color: color,
      foreground: fg,
      fontSize: fs * BioFont.factor(s.font),
      fontWeight: FontWeight.w800,
      height: 1.18,
      letterSpacing: s.spacing * fs,
      shadows: sh,
    );
    final width = math.max(1.0, maxWidth - padH * 2);
    fillStyle = style(fill, null, shadows);
    _fill = TextPainter(
      text: TextSpan(text: s.text, style: fillStyle),
      textAlign: s.textAlign,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: width);
    if (s.outline) {
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = fs * 0.09
        ..strokeJoin = StrokeJoin.round
        ..color = lightText ? Colors.black : Colors.white;
      strokeStyle = style(null, stroke, null);
      _stroke = TextPainter(
        text: TextSpan(text: s.text, style: strokeStyle),
        textAlign: s.textAlign,
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      )..layout(maxWidth: width);
    }
    size = Size(_fill.width + padH * 2, _fill.height + padV * 2);
    if (hasBox) {
      _bgColor = switch (s.bg) {
        TextBg.inverse => s.color,
        TextBg.soft =>
          lightText
              ? Colors.black.withValues(alpha: 0.5)
              : Colors.white.withValues(alpha: 0.6),
        _ => lightText ? const Color(0xDD000000) : Colors.white,
      };
      _bgPath = _linesPath();
    }
  }

  final TextSpec spec;
  final double fontSize;
  late final double padH;
  late final double padV;
  late final Size size;
  late final TextPainter _fill;
  TextPainter? _stroke;

  /// For the widget (real Text widgets on top of the box).
  late final TextStyle fillStyle;
  TextStyle? strokeStyle;

  double get textWidth => _fill.width;
  Path? _bgPath;
  Color? _bgColor;

  /// One rounded box per line, joined (like Instagram).
  Path _linesPath() {
    final r = fontSize * 0.3;
    var path = Path();
    var y = 0.0;
    var first = true;
    for (final lm in _fill.computeLineMetrics()) {
      final top = y;
      y += lm.height;
      if (lm.width < 0.5) continue; // empty line
      final rect = Rect.fromLTRB(
        lm.left,
        top,
        lm.left + lm.width + padH * 2,
        y + padV * 2,
      );
      final rr = RRect.fromRectAndRadius(
        rect,
        Radius.circular(math.min(r, rect.height / 2)),
      );
      final p = Path()..addRRect(rr);
      path = first ? p : Path.combine(PathOperation.union, path, p);
      first = false;
    }
    return path;
  }

  /// Paints with the top-left corner at [o].
  void paint(Canvas canvas, Offset o) {
    paintBox(canvas, o);
    final at = o + Offset(padH, padV);
    _stroke?.paint(canvas, at);
    _fill.paint(canvas, at);
  }

  /// Only the background box(es).
  void paintBox(Canvas canvas, Offset o) {
    final bg = _bgPath;
    final color = _bgColor;
    if (bg != null && color != null) {
      canvas.drawPath(
        bg.shift(o),
        Paint()
          ..color = color
          ..isAntiAlias = true,
      );
    }
  }

  /// Paints with the middle at [center], turned by [rotation] (radians).
  void paintAt(Canvas canvas, Offset center, {double rotation = 0}) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    if (rotation != 0) canvas.rotate(rotation);
    paint(canvas, Offset(-size.width / 2, -size.height / 2));
    canvas.restore();
  }

  void dispose() {
    _fill.dispose();
    _stroke?.dispose();
  }
}

/// A [TextSpec] as a widget ([fontSize] in pixels, at most [maxWidth]).
class StyledText extends StatefulWidget {
  const StyledText({
    super.key,
    required this.spec,
    required this.fontSize,
    required this.maxWidth,
  });

  final TextSpec spec;
  final double fontSize;
  final double maxWidth;

  @override
  State<StyledText> createState() => _StyledTextState();
}

class _StyledTextState extends State<StyledText> {
  StyledTextLayout? _layout;

  StyledTextLayout _make() => StyledTextLayout(
    widget.spec,
    fontSize: widget.fontSize,
    maxWidth: widget.maxWidth,
  );

  @override
  void didUpdateWidget(StyledText old) {
    super.didUpdateWidget(old);
    final a = old.spec, b = widget.spec;
    if (old.fontSize != widget.fontSize ||
        old.maxWidth != widget.maxWidth ||
        a.text != b.text ||
        a.color != b.color ||
        a.font != b.font ||
        a.bg != b.bg ||
        a.align != b.align ||
        a.outline != b.outline ||
        a.glow != b.glow ||
        a.spacing != b.spacing ||
        a.shadow != b.shadow) {
      _layout?.dispose();
      _layout = null;
    }
  }

  @override
  void dispose() {
    _layout?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = _layout ??= _make();
    final s = widget.spec;
    Widget text(TextStyle style) => Text(
      s.text,
      textAlign: s.textAlign,
      textScaler: TextScaler.noScaling,
      style: style,
    );
    final stroke = l.strokeStyle;
    return SizedBox.fromSize(
      size: l.size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: CustomPaint(painter: _BoxPainter(l))),
          Positioned(
            left: l.padH,
            top: l.padV,
            // a hair wider so the lines break the same as the layout
            width: l.textWidth + 0.5,
            child: stroke == null
                ? text(l.fillStyle)
                : Stack(
                    children: [
                      ExcludeSemantics(child: text(stroke)),
                      text(l.fillStyle),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _BoxPainter extends CustomPainter {
  _BoxPainter(this.layout);
  final StyledTextLayout layout;

  @override
  void paint(Canvas canvas, Size size) => layout.paintBox(canvas, Offset.zero);

  @override
  bool shouldRepaint(_BoxPainter old) => !identical(old.layout, layout);
}
