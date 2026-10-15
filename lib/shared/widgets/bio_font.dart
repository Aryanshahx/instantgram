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
  };

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

/// Row of "Aa" chips to choose a bio font.
class BioFontPicker extends StatelessWidget {
  const BioFontPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.accent = const Color(0xFFC6FF3D),
  });

  final String value;
  final ValueChanged<String> onChanged;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final cur = BioFont.normalize(value);
    return SizedBox(
      height: 64,
      child: ListView.separated(
        key: const ValueKey('bio-fonts'),
        scrollDirection: Axis.horizontal,
        itemCount: BioFont.ids.length,
        separatorBuilder: (context, i) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final id = BioFont.ids[i];
          final on = id == cur;
          return GestureDetector(
            key: ValueKey('bio-font-${id.isEmpty ? 'normal' : id}'),
            onTap: () => onChanged(id),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 70,
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
                        fontSize: 19,
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
