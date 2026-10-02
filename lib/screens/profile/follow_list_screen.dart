import 'package:flutter/material.dart';

import '../../core/theme.dart';
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
      appBar: AppBar(title: Text(widget.followers ? 'Followers' : 'Following')),
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
              icon: Icons.group_outlined,
              title: widget.followers ? 'No followers yet' : 'Not following anyone',
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            itemCount: users.length,
            itemBuilder: (context, i) {
              final u = users[i];
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: context.card,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: context.hairline.withValues(alpha: 0.7)),
                ),
                child: ListTile(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24)),
                  contentPadding: const EdgeInsets.all(10),
                  leading: UserAvatar(url: u.photoUrl, name: u.username, radius: 24),
                  title: Text(u.username,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: u.fullName.isEmpty ? null : Text(u.fullName),
                  trailing: SizedBox(
                      width: 104, child: FollowButton(uid: u.uid, compact: true)),
                  onTap: () => openScreen(context, ProfileScreen(uid: u.uid)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
