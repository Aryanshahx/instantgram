import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../services/auth_service.dart';
import '../../services/post_pager.dart';
import '../../services/post_service.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/follow_button.dart';
import '../../widgets/post_grid.dart';
import '../../widgets/state_views.dart';
import '../../core/app_events.dart';
import 'edit_profile_screen.dart';
import 'follow_list_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.uid, this.isTab = false});

  final String uid;

  /// true when shown as the bottom-nav tab (no back button, has log out).
  final bool isTab;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final PostPager _pager = PostPager(
    () => PostService.instance.userPostsQuery(widget.uid),
    pageSize: 18,
  );
  final ScrollController _scroll = ScrollController();

  bool get _isMe => widget.uid == UserService.instance.myUid;

  @override
  void initState() {
    super.initState();
    _pager.loadMore();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 500) {
        _pager.loadMore();
      }
    });
    AppEvents.feedRefresh.addListener(_onRefresh);
  }

  void _onRefresh() => _pager.refresh();

  @override
  void dispose() {
    AppEvents.feedRefresh.removeListener(_onRefresh);
    _scroll.dispose();
    _pager.dispose();
    super.dispose();
  }

  Future<void> _logout() async {
    final ok = await confirm(
      context,
      title: 'Log out?',
      confirmLabel: 'Log out',
      destructive: true,
    );
    if (ok) await AuthService.instance.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AppUser?>(
      stream: UserService.instance.watchUser(widget.uid),
      builder: (context, snap) {
        final user = snap.data;
        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: !widget.isTab,
            title: Text(user?.username ?? '',
                style: const TextStyle(fontWeight: FontWeight.w800)),
            actions: [
              if (widget.isTab)
                IconButton(
                  tooltip: 'Log out',
                  icon: const Icon(Icons.logout),
                  onPressed: _logout,
                ),
            ],
          ),
          body: snap.hasError
              ? ErrorState(error: snap.error!, onRetry: () => setState(() {}))
              : user == null
                  ? (snap.connectionState == ConnectionState.waiting
                      ? const CenteredLoader()
                      : const EmptyState(
                          icon: Icons.person_off_outlined,
                          title: 'User not found'))
                  : _body(context, user),
        );
      },
    );
  }

  Widget _body(BuildContext context, AppUser user) {
    return ListenableBuilder(
      listenable: _pager,
      builder: (context, _) {
        return RefreshIndicator(
          onRefresh: () async {
            await _pager.refresh();
          },
          child: CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _header(context, user)),
              const SliverToBoxAdapter(child: Divider()),
              if (_pager.initialLoading)
                const SliverFillRemaining(
                    hasScrollBody: false, child: CenteredLoader())
              else if (_pager.error != null && _pager.posts.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: ErrorState(error: _pager.error!, onRetry: _pager.retry),
                )
              else if (_pager.posts.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: Icons.photo_camera_outlined,
                    title: _isMe ? 'Share your first post' : 'No posts yet',
                    subtitle: _isMe
                        ? 'Tap + to post a photo or a video link.'
                        : null,
                  ),
                )
              else
                PostGridSliver(posts: _pager.posts),
              if (_pager.loading && _pager.posts.isNotEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2.5)),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, AppUser user) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              UserAvatar(url: user.photoUrl, radius: 42),
              const SizedBox(width: 20),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _Stat(label: 'Posts', value: user.postsCount),
                    _Stat(
                      label: 'Followers',
                      value: user.followersCount,
                      onTap: () => openScreen(
                        context,
                        FollowListScreen(uid: user.uid, followers: true),
                      ),
                    ),
                    _Stat(
                      label: 'Following',
                      value: user.followingCount,
                      onTap: () => openScreen(
                        context,
                        FollowListScreen(uid: user.uid, followers: false),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (user.fullName.isNotEmpty)
            Text(user.fullName,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          if (user.bio.isNotEmpty) Text(user.bio),
          const SizedBox(height: 14),
          if (_isMe)
            OutlinedButton(
              onPressed: () =>
                  openScreen(context, EditProfileScreen(user: user)),
              child: const Text('Edit profile'),
            )
          else
            FollowButton(uid: user.uid),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.onTap});
  final String label;
  final int value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          children: [
            Text('$value',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            Text(label, style: TextStyle(color: context.muted, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
