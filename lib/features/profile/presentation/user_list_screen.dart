import 'package:flutter/material.dart';

import '../../../core/services/content_filter.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/user_tile.dart';
import '../data/user_repository.dart';

class UserListScreen extends StatefulWidget {
  const UserListScreen({super.key, required this.uid, required this.followers});

  final String uid;
  final bool followers;

  @override
  State<UserListScreen> createState() => _UserListScreenState();
}

class _UserListScreenState extends State<UserListScreen> {
  late final Future<List<UserProfile>> _future = UserRepository.instance
      .connections(widget.uid, followers: widget.followers);
  final Set<String> _removed = {};

  bool get _myFollowers =>
      widget.followers && widget.uid == ContentFilter.instance.uid;

  Future<void> _remove(UserProfile u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Remove follower?'),
        content: Text(
          "We won't tell @${u.username} they were removed from your followers.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text(
              'Remove',
              style: TextStyle(color: AppColors.like),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await UserRepository.instance.removeFollower(u.uid);
      if (mounted) setState(() => _removed.add(u.uid));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.followers ? 'Followers' : 'Following')),
      body: FutureBuilder<List<UserProfile>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorView(error: snap.error);
          if (!snap.hasData) return const LoadingView();
          final users = snap.data!
              .where(
                (u) =>
                    !_removed.contains(u.uid) &&
                    !ContentFilter.instance.isBlocked(u.uid),
              )
              .toList();
          if (users.isEmpty) {
            return Center(
              child: EmptyState(
                icon: Icons.people_outline,
                title: widget.followers
                    ? 'No followers yet'
                    : 'Not following anyone',
              ),
            );
          }
          return ListView.builder(
            itemCount: users.length,
            itemBuilder: (context, i) => UserTile(
              user: users[i],
              onTap: () => openProfile(context, users[i].uid),
              trailing: _myFollowers
                  ? OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      onPressed: () => _remove(users[i]),
                      child: const Text('Remove'),
                    )
                  : null,
            ),
          );
        },
      ),
    );
  }
}
