import 'package:flutter/material.dart';

import '../../core/services/account_status.dart';

/// v0.13: blue badge next to a username (only for accounts the admin
/// verified). Shows nothing for everyone else.
class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({super.key, required this.uid, this.size = 15});

  final String uid;
  final double size;

  static const Color color = Color(0xFF3897F0);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: AccountStatus.instance.verified,
      builder: (context, set, _) => uid.isNotEmpty && set.contains(uid)
          ? Padding(
              key: const ValueKey('verified-badge'),
              padding: const EdgeInsets.only(left: 3),
              child: Icon(Icons.verified, size: size, color: color),
            )
          : const SizedBox.shrink(),
    );
  }
}
