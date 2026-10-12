import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/services/content_filter.dart';
import '../../../core/services/media_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/email.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/share.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/ig_buttons.dart';
import '../../../shared/widgets/net_image.dart';
import '../../../shared/widgets/post_grid.dart';
import '../../chats/presentation/chats_screen.dart';
import '../../dashboard/presentation/dashboard_screen.dart';
import '../../post/data/post_repository.dart';
import '../../post/data/report_repository.dart';
import '../../post/presentation/create_sheet.dart';
import '../../settings/presentation/settings_screen.dart';
import '../data/user_repository.dart';
import 'edit_profile_screen.dart';
import 'user_list_screen.dart';

/// Profile of any user. [standalone] = opened as its own page (shows back button).
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key, required this.uid, this.standalone = false});

  final String uid;
  final bool standalone;

  @override
  Widget build(BuildContext context) {
    final body = StreamBuilder<UserProfile?>(
      stream: UserRepository.instance.watchUser(uid),
      builder: (context, snap) {
        if (snap.hasError) return Center(child: ErrorView(error: snap.error));
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const LoadingView();
        }
        var profile = snap.data;
        final authUser = FirebaseAuth.instance.currentUser;
        if (profile == null) {
          if (uid != authUser?.uid) {
            return const Center(
              child: EmptyState(
                icon: Icons.person_off_outlined,
                title: 'User not found',
              ),
            );
          }
          profile = UserProfile(
            uid: uid,
            name: authUser?.displayName ?? '',
            username: (authUser?.email ?? 'user').split('@').first,
            email: authUser?.email ?? '',
          );
        }
        return ProfileView(
          profile: profile,
          isMe: uid == authUser?.uid,
          standalone: standalone,
        );
      },
    );
    return standalone ? Scaffold(body: body) : body;
  }
}

class ProfileView extends StatefulWidget {
  const ProfileView({
    super.key,
    required this.profile,
    required this.isMe,
    this.standalone = false,
  });

  final UserProfile profile;
  final bool isMe;
  final bool standalone;

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this)
    ..addListener(() => setState(() {}));

  late Stream<List<Post>> _posts;
  late Stream<List<Post>> _clips;
  late Stream<List<String>> _reposts;

  @override
  void initState() {
    super.initState();
    _initStreams();
  }

  void _initStreams() {
    final uid = widget.profile.uid;
    _posts = PostRepository.instance.byUser(uid, type: Post.photo);
    _clips = PostRepository.instance.byUser(uid, type: Post.clip);
    _reposts = PostRepository.instance.repostIds(uid);
  }

  @override
  void didUpdateWidget(covariant ProfileView old) {
    super.didUpdateWidget(old);
    if (old.profile.uid != widget.profile.uid) _initStreams();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _changePhoto() async {
    final file = await MediaService.instance.pick(context, maxWidth: 800);
    if (file == null || !mounted) return;
    final ok = await runWithProgress(
      context,
      title: 'Updating photo',
      task: (p) => UserRepository.instance.changePhoto(file, onProgress: p),
    );
    if (ok) _snack('Profile photo updated');
  }

  Future<void> _changeCover() async {
    final file = await MediaService.instance.pick(context, maxWidth: 1600);
    if (file == null || !mounted) return;
    final ok = await runWithProgress(
      context,
      title: 'Updating cover',
      task: (p) => UserRepository.instance.changeCover(file, onProgress: p),
    );
    if (ok) _snack('Cover updated');
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(profile: widget.profile),
      ),
    );
  }

  // ---------- ⋯ menu on other people's profiles ----------

  Future<void> _openUserMenu() async {
    final p = widget.profile;
    final blocked = ContentFilter.instance.isBlocked(p.uid);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            Text(
              '@${p.username}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            ListTile(
              dense: true,
              leading: const Icon(Icons.share_outlined),
              title: const Text('Share profile'),
              onTap: () => Navigator.pop(ctx, 'share'),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.flag_outlined, color: AppColors.like),
              title: const Text(
                'Report',
                style: TextStyle(color: AppColors.like),
              ),
              subtitle: const Text('Opens your email app'),
              onTap: () => Navigator.pop(ctx, 'report'),
            ),
            ListTile(
              key: const ValueKey('menu-block'),
              dense: true,
              leading: Icon(
                blocked ? Icons.lock_open : Icons.block,
                color: AppColors.like,
              ),
              title: Text(
                blocked ? 'Unblock' : 'Block',
                style: const TextStyle(color: AppColors.like),
              ),
              onTap: () => Navigator.pop(ctx, blocked ? 'unblock' : 'block'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'share':
        shareProfile(p);
      case 'report':
        await _reportUser();
      case 'block':
        await _block();
      case 'unblock':
        await _unblock();
    }
  }

  Future<void> _reportUser() async {
    final p = widget.profile;
    var reporter = '';
    var reporterUid = ContentFilter.instance.uid;
    try {
      final me = await UserRepository.instance.meCached();
      reporter = me.username;
      reporterUid = me.uid;
    } catch (_) {}
    if (!mounted) return;
    final mail = ReportRepository.userEmail(
      user: p,
      message: 'Please describe the problem here: ',
      reporterUsername: reporter,
      reporterUid: reporterUid,
    );
    final ok = await openEmail(
      context,
      to: ReportRepository.to,
      subject: mail.subject,
      body: mail.body,
    );
    if (ok && mounted) _snack('Press Send in your email app to report');
  }

  Future<void> _block() async {
    final p = widget.profile;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Block @${p.username}?'),
        content: const Text(
          "They won't be able to message you, follow you or comment on your "
          "posts, and you won't see their content. They won't be told.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Block', style: TextStyle(color: AppColors.like)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await UserRepository.instance.block(p);
      _snack('Blocked @${p.username}');
    } catch (e) {
      _snack(friendlyError(e));
    }
  }

  Future<void> _unblock() async {
    try {
      await UserRepository.instance.unblock(widget.profile.uid);
      _snack('Unblocked @${widget.profile.username}');
    } catch (e) {
      _snack(friendlyError(e));
    }
  }

  void _editProfile() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditProfileScreen(profile: widget.profile),
      ),
    );
  }

  void _openList(bool followers) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            UserListScreen(uid: widget.profile.uid, followers: followers),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: ContentFilter.instance.version,
      builder: (context, v, child) => _buildProfile(context),
    );
  }

  Widget _buildProfile(BuildContext context) {
    final p = widget.profile;
    final f = ContentFilter.instance;
    final blocked = !widget.isMe && f.isBlocked(p.uid);
    final locked =
        !widget.isMe && !blocked && p.isPrivate && !f.isFollowing(p.uid);
    final hidden = blocked || locked;
    return NestedScrollView(
      headerSliverBuilder: (context, _) => [
        SliverToBoxAdapter(
          child: _Header(
            profile: p,
            isMe: widget.isMe,
            onBack: widget.standalone
                ? () => Navigator.of(context).maybePop()
                : null,
            onSettings: _openSettings,
            onMore: _openUserMenu,
            blocked: blocked,
            onUnblock: _unblock,
            onEdit: _editProfile,
            onShare: () => shareProfile(p),
            onDashboard: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const DashboardScreen())),
            onAddPhoto: _changePhoto,
            onCoverTap: widget.isMe ? _changeCover : null,
            onNewStory: () => startCompose(context, ComposeMode.story),
            onPostsTap: () => _tabs.animateTo(0),
            onFollowersTap: hidden ? null : () => _openList(true),
            onFollowingTap: hidden ? null : () => _openList(false),
          ),
        ),
        SliverPersistentHeader(
          pinned: true,
          delegate: _TabBarDelegate(
            TabBar(
              controller: _tabs,
              indicatorColor: AppColors.lime,
              indicatorWeight: 3,
              indicatorSize: TabBarIndicatorSize.tab,
              labelPadding: const EdgeInsets.symmetric(horizontal: 4),
              dividerColor: AppColors.border,
              labelColor: AppColors.textPrimary,
              unselectedLabelColor: AppColors.textSecondary,
              labelStyle: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                fontFamily: 'Inter',
              ),
              tabs: [
                _tab(0, Icons.grid_view_rounded, 'Posts'),
                _tab(1, Icons.smart_display, 'Clips'),
                _tab(2, Icons.repeat, 'Reposts'),
              ],
            ),
          ),
        ),
      ],
      body: hidden
          ? _HiddenNotice(blocked: blocked, username: p.username)
          : TabBarView(
              controller: _tabs,
              children: [
                _StreamGrid(
                  stream: _posts,
                  emptyIcon: Icons.photo_camera_outlined,
                  emptyTitle: 'No posts yet',
                  emptySubtitle: widget.isMe
                      ? 'Tap + to share your first photo.'
                      : null,
                  onCreate: widget.isMe ? () => showCreateSheet(context) : null,
                ),
                _StreamGrid(
                  stream: _clips,
                  emptyIcon: Icons.smart_display_outlined,
                  emptyTitle: 'No clips yet',
                  emptySubtitle: widget.isMe
                      ? 'Your short videos will appear here.'
                      : null,
                ),
                _RepostsTab(ids: _reposts, isMe: widget.isMe),
              ],
            ),
    );
  }

  Widget _tab(int i, IconData icon, String label) {
    final selected = _tabs.index == i;
    return Tab(
      height: 46, // Flutter's minimum tab height (smaller breaks the layout)
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 18,
            color: selected ? AppColors.lime : AppColors.textSecondary,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label, overflow: TextOverflow.fade, softWrap: false),
          ),
        ],
      ),
    );
  }
}

class _StreamGrid extends StatelessWidget {
  const _StreamGrid({
    required this.stream,
    required this.emptyIcon,
    required this.emptyTitle,
    this.emptySubtitle,
    this.onCreate,
  });

  final Stream<List<Post>> stream;
  final IconData emptyIcon;
  final String emptyTitle;
  final String? emptySubtitle;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Post>>(
      stream: stream,
      builder: (context, snap) {
        if (snap.hasError) {
          return SingleChildScrollView(child: ErrorView(error: snap.error));
        }
        if (!snap.hasData) return const LoadingView();
        final posts = snap.data!;
        return PostGrid(
          posts: posts,
          onTap: (i) => openPost(context, posts, i),
          emptyIcon: emptyIcon,
          emptyTitle: emptyTitle,
          emptySubtitle: emptySubtitle,
        );
      },
    );
  }
}

class _RepostsTab extends StatefulWidget {
  const _RepostsTab({required this.ids, required this.isMe});
  final Stream<List<String>> ids;
  final bool isMe;

  @override
  State<_RepostsTab> createState() => _RepostsTabState();
}

class _RepostsTabState extends State<_RepostsTab> {
  String _key = '';
  Future<List<Post>>? _future;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<String>>(
      stream: widget.ids,
      builder: (context, snap) {
        if (snap.hasError) {
          return SingleChildScrollView(child: ErrorView(error: snap.error));
        }
        if (!snap.hasData) return const LoadingView();
        final ids = snap.data!;
        final key = ids.join(',');
        if (key != _key || _future == null) {
          _key = key;
          _future = PostRepository.instance.byIds(ids);
        }
        return FutureBuilder<List<Post>>(
          future: _future,
          builder: (context, f) {
            if (f.hasError) {
              return SingleChildScrollView(child: ErrorView(error: f.error));
            }
            if (!f.hasData) return const LoadingView();
            final posts = f.data!;
            return PostGrid(
              posts: posts,
              onTap: (i) => openPost(context, posts, i),
              emptyIcon: Icons.repeat,
              emptyTitle: 'No reposts yet',
              emptySubtitle: widget.isMe
                  ? 'Posts you repost will appear here.'
                  : null,
            );
          },
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.profile,
    required this.isMe,
    required this.onBack,
    required this.onSettings,
    required this.onMore,
    required this.blocked,
    required this.onUnblock,
    required this.onEdit,
    required this.onShare,
    required this.onDashboard,
    required this.onAddPhoto,
    required this.onCoverTap,
    required this.onNewStory,
    required this.onPostsTap,
    required this.onFollowersTap,
    required this.onFollowingTap,
  });

  final UserProfile profile;
  final bool isMe;
  final VoidCallback? onBack;
  final VoidCallback onSettings;
  final VoidCallback onMore;
  final bool blocked;
  final VoidCallback onUnblock;
  final VoidCallback onEdit;
  final VoidCallback onShare;
  final VoidCallback onDashboard;
  final VoidCallback onAddPhoto;
  final VoidCallback? onCoverTap;
  final VoidCallback onNewStory;
  final VoidCallback onPostsTap;
  final VoidCallback? onFollowersTap;
  final VoidCallback? onFollowingTap;

  static const double _coverHeight = 140;
  static const double _avatarSize = 80;

  Widget _circleButton(IconData icon, String tip, VoidCallback onTap) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tip,
        onPressed: onTap,
        iconSize: 20,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, color: Colors.white),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    final p = profile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: _coverHeight + topPad + _avatarSize * 0.45,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 12,
                right: 12,
                top: 0,
                height: _coverHeight + topPad,
                child: GestureDetector(
                  onTap: onCoverTap,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(26),
                    ),
                    child: p.coverUrl.isEmpty
                        ? const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Color(0xFF1B1F6B),
                                  Color(0xFF2E3FD6),
                                  Color(0xFF0E1446),
                                ],
                              ),
                            ),
                          )
                        : NetImage(p.coverUrl),
                  ),
                ),
              ),
              if (onBack != null)
                Positioned(
                  left: 24,
                  top: topPad + 8,
                  child: _circleButton(Icons.arrow_back, 'Back', onBack!),
                ),
              if (isMe)
                Positioned(
                  right: 24,
                  top: topPad + 8,
                  child: _circleButton(Icons.settings, 'Settings', onSettings),
                )
              else
                Positioned(
                  right: 24,
                  top: topPad + 8,
                  child: _circleButton(Icons.more_horiz, 'More', onMore),
                ),
              Positioned(
                left: 26,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: const BoxDecoration(
                    color: AppColors.background,
                    shape: BoxShape.circle,
                  ),
                  child: GestureDetector(
                    onTap: isMe ? onAddPhoto : null,
                    child: Avatar(
                      url: p.photoUrl,
                      name: p.displayName,
                      size: _avatarSize,
                      uid: p.uid,
                      showPlus: isMe,
                      onPlusTap: onAddPhoto,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                p.displayName,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      '@${p.username}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  if (p.isPrivate) ...[
                    const SizedBox(width: 5),
                    const Icon(
                      Icons.lock,
                      size: 13,
                      color: AppColors.textSecondary,
                    ),
                  ],
                ],
              ),
              if (p.bio.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  p.bio,
                  style: const TextStyle(fontSize: 14.5, height: 1.35),
                ),
              ],
              if (p.website.isNotEmpty) ...[
                const SizedBox(height: 10),
                _LinkChip(
                  label: p.website,
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: p.website));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Link copied')),
                      );
                    }
                  },
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  _Stat(value: p.postsCount, label: 'Posts', onTap: onPostsTap),
                  _Stat(
                    value: p.followersCount,
                    label: 'Followers',
                    onTap: onFollowersTap,
                  ),
                  _Stat(
                    value: p.followingCount,
                    label: 'Following',
                    onTap: onFollowingTap,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (isMe) ...[
                Row(
                  children: [
                    Expanded(
                      child: IgPrimaryButton(
                        label: 'Edit profile',
                        height: 36,
                        onPressed: onEdit,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: IgOutlineButton(
                        label: 'Share profile',
                        height: 36,
                        onPressed: onShare,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                IgOutlineButton(
                  label: 'Dashboard',
                  icon: Icons.auto_graph,
                  height: 36,
                  onPressed: onDashboard,
                ),
                const SizedBox(height: 14),
                _NewHighlight(onTap: onNewStory),
                const SizedBox(height: 10),
              ] else if (blocked) ...[
                IgOutlineButton(
                  label: 'Unblock',
                  height: 36,
                  onPressed: onUnblock,
                ),
                const SizedBox(height: 14),
              ] else ...[
                _FollowRow(profile: p),
                const SizedBox(height: 14),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _FollowRow extends StatefulWidget {
  const _FollowRow({required this.profile});
  final UserProfile profile;

  @override
  State<_FollowRow> createState() => _FollowRowState();
}

class _FollowRowState extends State<_FollowRow> {
  late final Stream<bool> _following = UserRepository.instance.isFollowing(
    widget.profile.uid,
  );
  late final Stream<bool> _requested = UserRepository.instance.hasRequested(
    widget.profile.uid,
  );
  bool _busy = false;

  Future<void> _run(Future<void> Function() task) async {
    setState(() => _busy = true);
    try {
      await task();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unfollow() async {
    final p = widget.profile;
    if (p.isPrivate) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text('Unfollow @${p.username}?'),
          content: const Text(
            "This account is private. You'll need to ask again to see "
            'their posts.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text(
                'Unfollow',
                style: TextStyle(color: AppColors.like),
              ),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _run(() => UserRepository.instance.unfollow(p));
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    return StreamBuilder<bool>(
      stream: _following,
      builder: (context, snap) {
        final following = snap.data ?? false;
        return StreamBuilder<bool>(
          stream: p.isPrivate && !following ? _requested : null,
          builder: (context, req) {
            final requested = req.data ?? false;
            Widget button;
            if (following) {
              button = IgOutlineButton(
                label: 'Following',
                icon: Icons.check,
                height: 36,
                onPressed: _busy ? null : _unfollow,
              );
            } else if (requested) {
              button = IgOutlineButton(
                key: const ValueKey('requested'),
                label: 'Requested',
                height: 36,
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => UserRepository.instance.cancelRequest(p.uid),
                      ),
              );
            } else {
              button = IgPrimaryButton(
                key: const ValueKey('follow'),
                label: 'Follow',
                height: 36,
                loading: _busy || !snap.hasData,
                onPressed: () => _run(
                  () => p.isPrivate
                      ? UserRepository.instance.requestFollow(p)
                      : UserRepository.instance.follow(p),
                ),
              );
            }
            return Row(
              children: [
                Expanded(child: button),
                const SizedBox(width: 8),
                Expanded(
                  child: IgOutlineButton(
                    label: 'Message',
                    height: 36,
                    onPressed: () => openChat(context, p),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Shown instead of the grids for private (not followed) or blocked accounts.
class _HiddenNotice extends StatelessWidget {
  const _HiddenNotice({required this.blocked, required this.username});
  final bool blocked;
  final String username;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 120),
      children: [
        Center(
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.textPrimary, width: 2),
            ),
            child: Icon(blocked ? Icons.block : Icons.lock_outline, size: 30),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          blocked ? 'You blocked @$username' : 'This account is private',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          blocked
              ? 'Unblock to see their posts and clips.'
              : 'Follow this account to see their photos, clips and moments.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final display = label
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceFirst(RegExp(r'/$'), '');
    return Material(
      color: AppColors.surface,
      shape: const StadiumBorder(side: BorderSide(color: AppColors.border)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link, color: AppColors.lime, size: 17),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: Text(
                  display,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.onTap});

  final int value;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              compactCount(value < 0 ? 0 : value),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewHighlight extends StatelessWidget {
  const _NewHighlight({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF2D3035),
              border: Border.all(color: const Color(0xFF808186), width: 1.5),
            ),
            child: const Icon(Icons.add, size: 26),
          ),
          const SizedBox(height: 5),
          const Text(
            'New',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  _TabBarDelegate(this.tabBar);

  final TabBar tabBar;

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: AppColors.background,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) => true;
}
