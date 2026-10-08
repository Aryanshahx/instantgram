import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/vanish.dart';

/// Pick how long messages in this chat live: Off, After seen, 24 hours or 7 days.
/// Returns the picked mode (one of [Vanish]) or null when closed.
Future<String?> showVanishPicker(BuildContext context, {String current = ''}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    builder: (ctx) {
      Widget tile(String mode, IconData icon, String sub) => ListTile(
        key: ValueKey('vanish_${mode.isEmpty ? 'off' : mode}'),
        leading: Icon(icon),
        title: Text(
          Vanish.label(mode),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(sub),
        trailing: mode == current
            ? Icon(Icons.check_rounded, color: context.accentInk)
            : null,
        onTap: () => Navigator.of(ctx).pop(mode),
      );
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(
                  'Disappearing messages',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  'New messages vanish for both of you. Either of you can change it.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.muted),
                ),
              ),
              tile(Vanish.off, Icons.block_rounded, 'Messages stay'),
              tile(
                Vanish.seen,
                Icons.visibility_rounded,
                'Gone after they are seen and the chat is closed',
              ),
              tile(
                Vanish.day,
                Icons.schedule_rounded,
                'Gone 24 hours after sending',
              ),
              tile(
                Vanish.week,
                Icons.date_range_rounded,
                'Gone 7 days after sending',
              ),
            ],
          ),
        ),
      );
    },
  );
}
