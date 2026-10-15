import 'dart:math' as math;

import 'package:flutter/material.dart';

/// v0.15: fonts you can choose for your bio (saved as `bioFont`).
class BioFont {
  BioFont._();

  /// id -> (name shown, font family, size factor)
  static const Map<String, (String, String, double)> all = {
    '': ('Normal', '', 1),
    'pacifico': ('Pacifico', 'Pacifico', 1.05),
    'lobster': ('Lobster', 'BioLobster', 1.1),
    'dancing': ('Dancing', 'BioDancing', 1.2),
    'caveat': ('Caveat', 'BioCaveat', 1.3),
    'bebas': ('Bebas', 'BioBebas', 1.25),
    'playfair': ('Classic', 'BioPlayfair', 1.05),
    'typewriter': ('Typewriter', 'BioTypewriter', 1),
    'comfortaa': ('Rounded', 'BioComfortaa', 1),
    'mono': ('Mono', 'BioMono', 0.95),
    'pixel': ('Pixel', 'BioPixel', 0.62),
    // v0.16: more fonts (bio, chat messages, moment / post text)
    'bangers': ('Bangers', 'BioBangers', 1.15),
    'marker': ('Marker', 'BioMarker', 1),
    'kaushan': ('Brush', 'BioKaushan', 1.05),
    'vibes': ('Elegant', 'BioVibes', 1.35),
    'righteous': ('Retro', 'BioRighteous', 1),
    'orbitron': ('Future', 'BioOrbitron', 0.9),
    'amatic': ('Sketch', 'BioAmatic', 1.4),
    'neon': ('Neon', 'BioNeon', 0.85),
    'comic': ('Comic', 'BioComic', 1),
    'shadows': ('Notes', 'BioShadows', 1.15),
    'fatface': ('Bold', 'BioFatface', 1.05),
    'spooky': ('Spooky', 'BioSpooky', 1.1),
  };

  /// v0.16: font family for texts drawn on photos / videos
  /// ('' or unknown = the app font).
  static String family(String id, String fallback) {
    final f = all[normalize(id)]!.$2;
    return f.isEmpty ? fallback : f;
  }

  /// v0.16: size factor of [id] (so every font looks about the same size).
  static double factor(String id) => all[normalize(id)]!.$3;

  static List<String> get ids => all.keys.toList();

  static String normalize(Object? v) =>
      v is String && all.containsKey(v) ? v : '';

  static String label(String id) => all[normalize(id)]!.$1;

  /// [base] in the bio font [id] (normal = [base] unchanged).
  static TextStyle style(String id, TextStyle base) {
    final f = all[normalize(id)]!;
    if (f.$2.isEmpty) return base;
    return base.copyWith(
      fontFamily: f.$2,
      fontSize: (base.fontSize ?? 14) * f.$3,
      height: f.$2 == 'BioPixel' ? 1.7 : base.height,
    );
  }
}

/// v0.16: one font for a part of a text (`bioFonts: [{s, e, f}]`).
/// [start] .. [end] are UTF-16 positions (like Dart strings).
class FontRun {
  const FontRun(this.start, this.end, this.font);

  final int start;
  final int end;
  final String font;

  Map<String, dynamic> toMap() => {'s': start, 'e': end, 'f': font};

  @override
  bool operator ==(Object other) =>
      other is FontRun &&
      other.start == start &&
      other.end == end &&
      other.font == font;

  @override
  int get hashCode => Object.hash(start, end, font);

  @override
  String toString() => 'FontRun($start, $end, $font)';
}

/// v0.16: many fonts in one text (bio).
abstract final class FontRuns {
  /// Most parts saved (Firestore rules allow 60).
  static const int maxRuns = 50;

  /// Reads `bioFonts` safely (bad / unknown parts are skipped).
  static List<FontRun> parse(Object? v, int textLength) {
    if (v is! List) return const [];
    final out = <FontRun>[];
    for (final m in v) {
      if (m is! Map) continue;
      final s = m['s'], e = m['e'], f = m['f'];
      if (s is! num || e is! num || f is! String) continue;
      final id = BioFont.normalize(f);
      if (id.isEmpty) continue;
      final a = s.toInt().clamp(0, textLength);
      final b = e.toInt().clamp(0, textLength);
      if (b <= a) continue;
      out.add(FontRun(a, b, id));
      if (out.length >= maxRuns) break;
    }
    return out;
  }

  /// Font of every character ('' = normal).
  static List<String> toChars(
    int length,
    List<FontRun> runs, {
    String fallback = '',
  }) {
    final chars = List<String>.filled(
      length,
      BioFont.normalize(fallback),
      growable: true,
    );
    for (final r in runs) {
      final a = r.start.clamp(0, length), b = r.end.clamp(0, length);
      for (var i = a; i < b; i++) {
        chars[i] = BioFont.normalize(r.font);
      }
    }
    return chars;
  }

  /// Characters -> parts (normal parts are not saved).
  static List<FontRun> fromChars(List<String> chars, [String text = '']) {
    final out = <FontRun>[];
    var i = 0;
    while (i < chars.length && out.length < maxRuns) {
      final f = chars[i];
      var j = i + 1;
      while (j < chars.length && chars[j] == f) {
        j++;
      }
      // never cut an emoji in two
      while (j < chars.length && j < text.length && _isLow(text, j)) {
        j++;
      }
      if (f.isNotEmpty) out.add(FontRun(i, j, f));
      i = j;
    }
    return out;
  }

  static bool _isLow(String t, int i) {
    final c = t.codeUnitAt(i);
    return c >= 0xDC00 && c <= 0xDFFF;
  }

  /// Text spans: each part in its font.
  static List<TextSpan> spans(
    String text,
    List<FontRun> runs,
    TextStyle base, {
    String fallback = '',
  }) {
    if (text.isEmpty) return const [];
    final chars = toChars(text.length, runs, fallback: fallback);
    final out = <TextSpan>[];
    var i = 0;
    while (i < text.length) {
      final f = chars[i];
      var j = i + 1;
      while (j < text.length && (chars[j] == f || _isLow(text, j))) {
        j++;
      }
      out.add(
        TextSpan(text: text.substring(i, j), style: BioFont.style(f, base)),
      );
      i = j;
    }
    return out;
  }

  /// [text] with [runs] after `trim()` (positions move with the text).
  static (String, List<FontRun>) trimmed(String text, List<FontRun> runs) {
    final t = text.trim();
    if (t.isEmpty) return ('', const []);
    final lead = text.indexOf(t);
    final out = <FontRun>[];
    for (final r in runs) {
      final a = math.max(0, r.start - lead);
      final b = math.min(t.length, r.end - lead);
      if (b > a) out.add(FontRun(a, b, r.font));
    }
    return (t, out);
  }
}

/// v0.16: a text field controller that keeps a font for every character.
/// Select words + [applyFont] = those words; no selection = the line
/// where the cursor is. New letters take the font of the letter before.
class FontRunController extends TextEditingController {
  FontRunController({
    String text = '',
    List<FontRun> runs = const [],
    String fallback = '',
  }) : _last = text,
       super(text: text) {
    _chars = FontRuns.toChars(text.length, runs, fallback: fallback);
    addListener(_sync);
  }

  late List<String> _chars;
  String _last;

  /// Font for the next letters typed on an empty line.
  String? _pending;
  int _pendingAt = -1;

  void _sync() {
    final t = text;
    if (t == _last) return;
    final old = _last;
    var pre = 0;
    final minLen = math.min(t.length, old.length);
    while (pre < minLen && t.codeUnitAt(pre) == old.codeUnitAt(pre)) {
      pre++;
    }
    var suf = 0;
    while (suf < minLen - pre &&
        t.codeUnitAt(t.length - 1 - suf) ==
            old.codeUnitAt(old.length - 1 - suf)) {
      suf++;
    }
    final added = t.length - pre - suf;
    final font =
        (_pending != null && pre == _pendingAt ? _pending : null) ??
        (pre > 0
            ? _chars[pre - 1]
            : (old.length - suf < _chars.length
                  ? _chars[old.length - suf]
                  : ''));
    _chars.replaceRange(pre, old.length - suf, List.filled(added, font));
    if (added > 0) _pending = null;
    _last = t;
  }

  /// Font of each part (for saving).
  List<FontRun> get runs {
    _sync();
    return FontRuns.fromChars(_chars, text);
  }

  /// Font at the cursor (for the picker).
  String get fontAtCursor {
    _sync();
    final sel = selection;
    if (_pending != null && sel.isCollapsed && sel.baseOffset == _pendingAt) {
      return _pending!;
    }
    if (_chars.isEmpty) return '';
    var i = sel.isValid ? sel.start : _chars.length;
    if (sel.isValid && !sel.isCollapsed) {
      return _chars[i.clamp(0, _chars.length - 1)];
    }
    i = i > 0 ? i - 1 : 0;
    return _chars[i.clamp(0, _chars.length - 1)];
  }

  /// Selected words, or the whole line of the cursor.
  void applyFont(String id) {
    _sync();
    final f = BioFont.normalize(id);
    final t = text;
    final sel = selection;
    int a, b;
    if (sel.isValid && !sel.isCollapsed) {
      a = sel.start;
      b = sel.end;
    } else {
      final c = sel.isValid ? sel.baseOffset.clamp(0, t.length) : t.length;
      a = c == 0 ? 0 : t.lastIndexOf('\n', c - 1) + 1;
      final nl = t.indexOf('\n', c);
      b = nl < 0 ? t.length : nl;
      _pending = f;
      _pendingAt = c;
    }
    for (var i = a; i < b && i < _chars.length; i++) {
      _chars[i] = f;
    }
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    _sync();
    final base = style ?? const TextStyle();
    return TextSpan(
      style: base,
      children: FontRuns.spans(text, FontRuns.fromChars(_chars, text), base),
    );
  }
}

/// Row of "Aa" chips to choose a bio font.
class BioFontPicker extends StatelessWidget {
  const BioFontPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.accent = const Color(0xFFC6FF3D),
    this.keyPrefix = 'bio-font',
    this.small = false,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final Color accent;

  /// v0.16: keys are `keyPrefix-id` (chat: `chat-font-id`).
  final String keyPrefix;

  /// v0.16: smaller chips (chat, editor).
  final bool small;

  @override
  Widget build(BuildContext context) {
    final cur = BioFont.normalize(value);
    return SizedBox(
      height: small ? 52 : 64,
      child: ListView.separated(
        key: ValueKey('${keyPrefix}s'),
        scrollDirection: Axis.horizontal,
        itemCount: BioFont.ids.length,
        separatorBuilder: (context, i) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final id = BioFont.ids[i];
          final on = id == cur;
          return GestureDetector(
            key: ValueKey('$keyPrefix-${id.isEmpty ? 'normal' : id}'),
            onTap: () => onChanged(id),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: small ? 58 : 70,
              decoration: BoxDecoration(
                color: on
                    ? accent.withValues(alpha: 0.14)
                    : Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: on ? accent : Colors.white12,
                  width: on ? 1.6 : 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Aa',
                    style: BioFont.style(
                      id,
                      TextStyle(
                        fontSize: small ? 16 : 19,
                        fontWeight: FontWeight.w600,
                        color: on ? accent : Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    BioFont.label(id),
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: on ? accent : Colors.white60,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
