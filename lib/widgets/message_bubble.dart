import 'package:flutter/material.dart';

import '../core/theme.dart';

/// One chat message. Mine are volt green on the right, theirs are grey on the left.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.text,
    required this.mine,
    required this.time,
    this.pending = false,
  });

  final String text;
  final bool mine;
  final String time;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.sizeOf(context).width * 0.74;
    final bg = mine ? AppTheme.volt : context.cardHigh;
    final fg = mine ? AppTheme.ink : Theme.of(context).colorScheme.onSurface;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW > 420 ? 420 : maxW),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(20),
              topRight: const Radius.circular(20),
              bottomLeft: Radius.circular(mine ? 20 : 5),
              bottomRight: Radius.circular(mine ? 5 : 20),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  text,
                  style: TextStyle(color: fg, fontSize: 15.5, height: 1.3),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                pending ? 'Sending...' : time,
                style: TextStyle(
                  color: fg.withValues(alpha: 0.55),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "14:05" for today, "Mon 14:05" within a week, otherwise "12 Sep".
String chatTime(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final local = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(local.hour)}:${two(local.minute)}';
  final sameDay =
      local.year == n.year && local.month == n.month && local.day == n.day;
  if (sameDay) return hm;
  final days = DateTime(
    n.year,
    n.month,
    n.day,
  ).difference(DateTime(local.year, local.month, local.day)).inDays;
  const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const mo = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  if (days >= 0 && days < 7) return '${wd[local.weekday - 1]} $hm';
  return '${local.day} ${mo[local.month - 1]}';
}
