import 'package:flutter/material.dart';

import '../../../core/services/content_filter.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../chats/presentation/chats_screen.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../core/theme/app_theme.dart';
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
  String get _me => ContentFilter.instance.uid;

  bool get _myFollowers => widget.followers && widget.uid == _me;

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
              .where((u) => !ContentFilter.instance.isBlocked(u.uid))
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
              trailing: users[i].uid == _me
                  ? null
                  : _myFollowers
                  ? FollowBackButton(user: users[i])
                  : !widget.followers
                  ? _SmallButton(
                      key: ValueKey('message-${users[i].uid}'),
                      label: 'Message',
                      onPressed: () => openChat(context, users[i]),
                    )
                  : null,
            ),
          );
        },
      ),
    );
  }
}

/// "Follow back" for someone who follows you (v0.7, replaces "Remove").
class FollowBackButton extends StatefulWidget {
  const FollowBackButton({super.key, required this.user});
  final UserProfile user;

  @override
  State<FollowBackButton> createState() => _FollowBackButtonState();
}

class _FollowBackButtonState extends State<FollowBackButton> {
  late final Stream<bool> _following = UserRepository.instance.isFollowing(
    widget.user.uid,
  );
  late final Stream<bool> _requested = UserRepository.instance.hasRequested(
    widget.user.uid,
  );
  bool _busy = false;

  Future<void> _follow() async {
    setState(() => _busy = true);
    final u = widget.user;
    try {
      if (u.isPrivate) {
        await UserRepository.instance.requestFollow(u);
      } else {
        await UserRepository.instance.follow(u);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    return StreamBuilder<bool>(
      stream: _following,
      builder: (context, f) {
        if (f.data ?? false) {
          return _SmallButton(
            key: ValueKey('following-${u.uid}'),
            label: 'Following',
            onPressed: null,
          );
        }
        return StreamBuilder<bool>(
          stream: u.isPrivate ? _requested : null,
          builder: (context, r) {
            if (r.data ?? false) {
              return _SmallButton(
                key: ValueKey('requested-${u.uid}'),
                label: 'Requested',
                onPressed: null,
              );
            }
            return _SmallButton(
              key: ValueKey('follow-back-${u.uid}'),
              label: 'Follow back',
              primary: true,
              onPressed: _busy || !f.hasData ? null : _follow,
            );
          },
        );
      },
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    const text = TextStyle(
      fontFamily: AppTheme.fontFamily,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    );
    const pad = EdgeInsets.symmetric(horizontal: 14);
    if (primary) {
      return FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.lime,
          foregroundColor: Colors.black,
          visualDensity: VisualDensity.compact,
          padding: pad,
          textStyle: text,
        ),
        onPressed: onPressed,
        child: Text(label),
      );
    }
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: pad,
        textStyle: text,
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}
