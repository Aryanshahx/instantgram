import 'package:flutter/material.dart';

import '../../core/services/bad_words.dart';
import '../../core/theme/app_colors.dart';

/// v0.18 Hyper Intelligence: checks [texts] for strong abuse / slurs
/// before they are saved. Shows a short message and returns false when
/// one is found (nothing is sent then).
Future<bool> hiTextOk(BuildContext context, List<String> texts) async {
  for (final t in texts) {
    final w = BadWords.find(t);
    if (w == null) continue;
    if (!context.mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('hi-word-dialog'),
        title: const Row(
          children: [
            Icon(Icons.shield_outlined, color: AppColors.lime, size: 22),
            SizedBox(width: 8),
            Text('Hyper Intelligence', style: TextStyle(fontSize: 17)),
          ],
        ),
        content: Text(
          'Please remove "${BadWords.mask(w)}". '
          'It breaks the InstantGram community rules.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('hi-word-ok'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return false;
  }
  return true;
}
