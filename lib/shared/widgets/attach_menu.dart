import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// One round button in the "+" menu.
class AttachOption {
  const AttachOption(this.id, this.icon, this.label, this.color);
  final String id;
  final IconData icon;
  final String label;
  final Color color;
}

/// The "+" menu (v0.10): chats and comments use the same one.
/// Returns the id of the tapped option, or null. Keys: '$keyPrefix-$id'.
Future<String?> showAttachMenu(
  BuildContext context,
  List<AttachOption> options, {
  String keyPrefix = 'attach',
  String? title,
}) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.surface,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            Wrap(
              alignment: WrapAlignment.spaceEvenly,
              runSpacing: 6,
              children: [
                for (final o in options)
                  SizedBox(
                    width: 84,
                    child: InkWell(
                      key: ValueKey('$keyPrefix-${o.id}'),
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => Navigator.pop(ctx, o.id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircleAvatar(
                              radius: 26,
                              backgroundColor: o.color,
                              child: Icon(o.icon, color: Colors.black, size: 25),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              o.label,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
