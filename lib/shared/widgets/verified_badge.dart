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

/// v0.14: a username with the blue badge after it (if verified). Use it
/// everywhere an account is shown.
class NameBadge extends StatelessWidget {
  const NameBadge(
    this.name, {
    super.key,
    required this.uid,
    this.style,
    this.badgeSize,
  });

  final String name;
  final String uid;
  final TextStyle? style;
  final double? badgeSize;

  @override
  Widget build(BuildContext context) {
    final fs = style?.fontSize ?? 14;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        VerifiedBadge(uid: uid, size: badgeSize ?? fs + 1),
      ],
    );
  }
}

/// v0.14: the badge inside a sentence (Text.rich).
InlineSpan verifiedSpan(String uid, {double size = 14}) => WidgetSpan(
  alignment: PlaceholderAlignment.middle,
  child: Padding(
    padding: const EdgeInsets.only(right: 3),
    child: VerifiedBadge(uid: uid, size: size),
  ),
);
