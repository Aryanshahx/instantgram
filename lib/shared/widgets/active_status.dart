import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/services/presence.dart';
import '../../core/theme/app_colors.dart';

/// "Active now" / "Active 5m ago" under a name (v0.10; v0.11 online flag). Shows nothing
/// when the person hides it, or when YOU hide yours.
class ActiveLabel extends StatefulWidget {
  const ActiveLabel({super.key, required this.uid, this.stream});
  final String uid;

  /// Tests.
  final Stream<PresenceState?>? stream;

  @override
  State<ActiveLabel> createState() => _ActiveLabelState();
}

class _ActiveLabelState extends State<ActiveLabel> {
  late final Stream<PresenceState?> _stream =
      widget.stream ?? Presence.instance.watch(widget.uid);
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // "2m ago" -> "3m ago" without new data
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PresenceState?>(
      stream: _stream,
      builder: (context, snap) {
        final text = Presence.labelOf(snap.data);
        if (text == null) return const SizedBox.shrink();
        final now = Presence.isNowOf(snap.data);
        return Text(
          text,
          key: const ValueKey('active-label'),
          maxLines: 1,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: now ? AppColors.lime : AppColors.textSecondary,
          ),
        );
      },
    );
  }
}

/// Small green dot on an avatar when the person is active now.
class ActiveDot extends StatefulWidget {
  const ActiveDot({super.key, required this.uid, this.size = 13});
  final String uid;
  final double size;

  @override
  State<ActiveDot> createState() => _ActiveDotState();
}

class _ActiveDotState extends State<ActiveDot> {
  late final Stream<PresenceState?> _stream = Presence.instance.watch(widget.uid);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PresenceState?>(
      stream: _stream,
      builder: (context, snap) {
        if (!Presence.isNowOf(snap.data)) return const SizedBox.shrink();
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: const Color(0xFF3DDC84),
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.background, width: 2),
          ),
        );
      },
    );
  }
}
