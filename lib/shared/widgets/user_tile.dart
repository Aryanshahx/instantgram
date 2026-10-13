import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../models/user_profile.dart';
import 'avatar.dart';

class UserTile extends StatelessWidget {
  const UserTile({super.key, required this.user, this.onTap, this.trailing});

  final UserProfile user;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      visualDensity: VisualDensity.compact,
      leading: Avatar(
        url: user.photoUrl,
        name: user.displayName,
        size: 42,
        uid: user.uid,
      ),
      title: Text(
        user.username,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
      subtitle: Text(
        user.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
      ),
      trailing: trailing,
    );
  }
}
