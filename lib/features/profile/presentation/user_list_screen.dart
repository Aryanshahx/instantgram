import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.followers ? 'Followers' : 'Following')),
      body: FutureBuilder<List<UserProfile>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorView(error: snap.error);
          if (!snap.hasData) return const LoadingView();
          final users = snap.data!;
          if (users.isEmpty) {
            return Center(
              child: EmptyState(
                icon: Icons.people_outline,
                title: widget.followers ? 'No followers yet' : 'Not following anyone',
              ),
            );
          }
          return ListView.builder(
            itemCount: users.length,
            itemBuilder: (context, i) => UserTile(
              user: users[i],
              onTap: () => openProfile(context, users[i].uid),
            ),
          );
        },
      ),
    );
  }
}
