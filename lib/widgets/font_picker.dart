import 'package:flutter/material.dart';

import '../core/fonts.dart';
import '../core/theme.dart';

/// A row of font chips (each written in its own font), for bios and messages.
/// '' is shown as "Normal".
class FontChipRow extends StatelessWidget {
  const FontChipRow({
    super.key,
    required this.selected,
    required this.onChanged,
    this.keyPrefix = 'font',
    this.enabled = true,
  });

  final String selected;
  final ValueChanged<String> onChanged;

  /// Keys are `prefix_id` (`prefix_normal` for '').
  final String keyPrefix;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final sel = cleanFontId(selected);
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          for (final f in kAppFonts)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                key: ValueKey('${keyPrefix}_${f.id.isEmpty ? 'normal' : f.id}'),
                selected: f.id == sel,
                showCheckmark: false,
                selectedColor: AppTheme.volt,
                onSelected: enabled ? (_) => onChanged(f.id) : null,
                label: Text(
                  f.id.isEmpty ? 'Normal' : f.label,
                  style: maybeAppFont(
                    f.id,
                    TextStyle(
                      fontSize: 14,
                      color: f.id == sel ? AppTheme.ink : null,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
