import 'package:flutter/material.dart';

import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/follow_button.dart';
import '../../widgets/state_views.dart';
import 'profile_screen.dart';

class FollowListScreen extends StatefulWidget {
  const FollowListScreen({super.key, required this.uid, required this.followers});

  final String uid;

  /// true = followers list, false = following list
  final bool followers;

  @override
  State<FollowListScreen> createState() => _FollowListScreenState();
}

class _FollowListScreenState extends State<FollowListScreen> {
  late Future<List<AppUser>> _future = _load();

  Future<List<AppUser>> _load() async {
    final svc = UserService.instance;
    final ids = widget.followers
        ? await svc.followerIds(widget.uid)
        : await svc.followingIds(widget.uid);
    return svc.getUsers(ids);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.followers ? 'Followers' : 'Following',
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: FutureBuilder<List<AppUser>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return ErrorState(
              error: snap.error!,
              onRetry: () => setState(() => _future = _load()),
            );
          }
          if (!snap.hasData) return const CenteredLoader();
          final users = snap.data!;
          if (users.isEmpty) {
            return EmptyState(
              icon: Icons.people_outline,
              title: widget.followers ? 'No followers yet' : 'Not following anyone',
            );
          }
          return ListView.builder(
            itemCount: users.length,
            itemBuilder: (context, i) {
              final u = users[i];
              return ListTile(
                leading: UserAvatar(url: u.photoUrl, radius: 24),
                title: Text(u.username,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: u.fullName.isEmpty ? null : Text(u.fullName),
                trailing: FollowButton(uid: u.uid, compact: true),
                onTap: () => openScreen(context, ProfileScreen(uid: u.uid)),
              );
            },
          );
        },
      ),
    );
  }
}
