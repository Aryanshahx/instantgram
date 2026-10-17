import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/avatar.dart';

/// v0.0.2: round picture of a group / channel (an icon when it has none).
class GroupAvatar extends StatelessWidget {
  const GroupAvatar({
    super.key,
    required this.url,
    required this.channel,
    this.size = 44,
  });

  final String url;
  final bool channel;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (url.isNotEmpty) return Avatar(url: url, size: size);
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: AppColors.surfaceHigh,
        shape: BoxShape.circle,
      ),
      child: Icon(
        channel ? Icons.campaign_outlined : Icons.groups_outlined,
        size: size * 0.52,
        color: AppColors.lime,
      ),
    );
  }
}

/// "alice is typing…", "alice and bob are typing…", "3 people are typing…"
String groupTypingText(List<String> names) {
  final n = names.where((s) => s.isNotEmpty).toList();
  if (n.isEmpty) return 'typing…';
  if (n.length == 1) return '${n.first} is typing…';
  if (n.length == 2) return '${n[0]} and ${n[1]} are typing…';
  return '${n.length} people are typing…';
}

/// "1 member", "12 members", "1.2K followers"
String memberCountText(int n, {required bool channel}) {
  final word = channel
      ? (n == 1 ? 'follower' : 'followers')
      : (n == 1 ? 'member' : 'members');
  final String count;
  if (n >= 1000000) {
    count = '${(n / 1000000).toStringAsFixed(1)}M';
  } else if (n >= 10000) {
    count = '${(n / 1000).round()}K';
  } else if (n >= 1000) {
    count = '${(n / 1000).toStringAsFixed(1)}K';
  } else {
    count = '$n';
  }
  return '${count.replaceAll('.0', '')} $word';
}
