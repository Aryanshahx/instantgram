import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_events.dart';
import '../../core/media_url.dart';
import '../../core/theme.dart';
import '../../core/responsive.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../models/post.dart';
import '../../services/auth_service.dart';
import '../../services/post_pager.dart';
import '../../services/post_service.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/follow_button.dart';
import '../../widgets/glass.dart';
import '../../widgets/pill_tabs.dart';
import '../../widgets/post_grid.dart';
import '../../widgets/state_views.dart';
import 'edit_profile_screen.dart';
import 'saved_posts_screen.dart';
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
    pageSize: 24,
  );
  late final Stream<AppUser?> _user = UserService.instance.watchUser(
    widget.uid,
  );
  final ScrollController _scroll = ScrollController();
  int _tab = 0; // 0 = Posts (photos), 1 = Clips (videos)

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
      stream: _user,
      builder: (context, snap) {
        final user = snap.data;
        if (user == null) {
          return Scaffold(
            appBar: widget.isTab ? null : AppBar(),
            body: SafeArea(
              child: snap.hasError
                  ? ErrorState(
                      error: snap.error!,
                      onRetry: () => setState(() {}),
                    )
                  : snap.connectionState == ConnectionState.waiting
                  ? const CenteredLoader()
                  : const EmptyState(
                      icon: Icons.person_off_outlined,
                      title: 'User not found',
                    ),
            ),
          );
        }
        return Scaffold(
          body: ContentWidth(maxWidth: 860, child: _body(context, user)),
        );
      },
    );
  }

  Widget _body(BuildContext context, AppUser user) {
    return ListenableBuilder(
      listenable: _pager,
      builder: (context, _) {
        final shown = <Post>[
          for (final p in _pager.posts)
            if (p.isVideo == (_tab == 1)) p,
        ];
        // a tab with few items on the first pages: keep loading until it has some
        if (shown.length < 9 &&
            _pager.hasMore &&
            !_pager.loading &&
            _pager.error == null &&
            _pager.posts.isNotEmpty) {
          Future.microtask(_pager.loadMore);
        }
        return RefreshIndicator(
          onRefresh: _pager.refresh,
          child: CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _header(context, user)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
                  child: PillTabs(
                    labels: const ['Posts', 'Clips'],
                    icons: const [
                      Icons.grid_view_rounded,
                      Icons.smart_display_rounded,
                    ],
                    index: _tab,
                    onChanged: (i) => setState(() => _tab = i),
                  ),
                ),
              ),
              if (_pager.initialLoading)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: CenteredLoader(),
                  ),
                )
              else if (_pager.error != null && _pager.posts.isEmpty)
                SliverToBoxAdapter(
                  child: ErrorState(
                    error: _pager.error!,
                    onRetry: _pager.retry,
                  ),
                )
              else if (shown.isEmpty && _pager.hasMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: CenteredLoader(),
                  ),
                )
              else if (shown.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: EmptyState(
                      icon: _tab == 0
                          ? Icons.photo_camera_outlined
                          : Icons.smart_display_outlined,
                      title: _tab == 0
                          ? (_isMe ? 'Share your first post' : 'No posts yet')
                          : (_isMe ? 'Share your first clip' : 'No clips yet'),
                      subtitle: _isMe
                          ? (_tab == 0
                                ? 'Tap + and choose Post to share a photo.'
                                : 'Tap + and choose Clips to upload a video.')
                          : null,
                    ),
                  ),
                )
              else
                PostGridSliver(posts: shown),
              if (_pager.loading && _pager.posts.isNotEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: kNavSpace)),
            ],
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, AppUser user) {
    final top = MediaQuery.of(context).padding.top;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---- banner with aurora colours + floating avatar
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              height: 150 + top,
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(36),
                ),
                gradient: AppTheme.auroraGradient,
                image: user.bannerUrl.isEmpty
                    ? null
                    : DecorationImage(
                        image: CachedNetworkImageProvider(
                          resolveMediaUrl(user.bannerUrl),
                          maxWidth: 1400,
                        ),
                        fit: BoxFit.cover,
                      ),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.violet.withValues(alpha: 0.25),
                    blurRadius: 30,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
            ),
            Positioned(
              top: top + 10,
              left: 24,
              right: 24,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (widget.isTab)
                    const SizedBox(width: 44)
                  else
                    GlassIconButton(
                      icon: Icons.arrow_back_rounded,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  if (widget.isTab)
                    GlassIconButton(
                      icon: Icons.logout_rounded,
                      tooltip: 'Log out',
                      onTap: _logout,
                    ),
                ],
              ),
            ),
            Positioned(
              left: 30,
              bottom: -44,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: context.bg,
                  shape: BoxShape.circle,
                ),
                child: UserAvatar(
                  url: user.photoUrl,
                  name: user.username,
                  radius: 42,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 54),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                user.fullName.isNotEmpty ? user.fullName : user.username,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(height: 2),
              Text('@${user.username}', style: TextStyle(color: context.muted)),
              if (user.bio.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  user.bio,
                  style: const TextStyle(fontSize: 15, height: 1.35),
                ),
              ],
              if (user.links.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (final l in user.links) _LinkChip(url: l)],
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  _Stat(label: 'Posts', value: user.postsCount),
                  const SizedBox(width: 10),
                  _Stat(
                    label: 'Followers',
                    value: user.followersCount,
                    onTap: () => openScreen(
                      context,
                      FollowListScreen(uid: user.uid, followers: true),
                    ),
                  ),
                  const SizedBox(width: 10),
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
              const SizedBox(height: 16),
              if (_isMe)
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () =>
                            openScreen(context, EditProfileScreen(user: user)),
                        icon: const Icon(Icons.edit_rounded, size: 18),
                        label: const Text('Edit profile'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 56,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(56, 56),
                        ),
                        onPressed: () =>
                            openScreen(context, const SavedPostsScreen()),
                        child: const Icon(Icons.bookmark_rounded),
                      ),
                    ),
                  ],
                )
              else
                FollowButton(uid: user.uid),
            ],
          ),
        ),
      ],
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
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: context.card,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: context.hairline.withValues(alpha: 0.7)),
          ),
          child: Column(
            children: [
              Text(
                '$value',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(color: context.muted, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tappable link on a profile.
class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.url});
  final String url;

  String get _label => url
      .replaceFirst(RegExp(r'^https?://'), '')
      .replaceFirst(RegExp(r'^www\.'), '')
      .replaceFirst(RegExp(r'/+$'), '');

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        final uri = Uri.tryParse(url);
        var ok = false;
        if (uri != null) {
          try {
            ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
          } catch (_) {}
        }
        if (!ok && context.mounted) {
          showToast(context, 'Could not open that link.');
        }
      },
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: context.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: context.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.link_rounded, size: 17, color: context.accentInk),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                _label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
