import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../chat/chat_screen.dart';
import '../story/story_composer.dart';
import '../../core/app_events.dart';
import '../../core/fonts.dart';
import '../../core/l10n.dart';
import '../../core/media_url.dart';
import '../../core/theme.dart';
import '../../core/responsive.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../models/post.dart';
import '../../services/safety_service.dart';
import '../../services/post_pager.dart';
import '../../services/post_service.dart';
import '../../services/user_service.dart';
import '../../widgets/moment_open.dart';
import '../../widgets/avatar.dart';
import '../../widgets/follow_button.dart';
import '../../widgets/glass.dart';
import '../../widgets/post_grid.dart';
import '../../widgets/state_views.dart';
import 'analytics_screen.dart';
import 'edit_profile_screen.dart';
import '../settings/account_screens.dart' show toggleBlock;
import '../settings/settings_screen.dart';
import 'follow_list_screen.dart';
import '../../widgets/highlights.dart';
import 'share_profile_screen.dart';

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
  int _tab = 0; // 0 = Posts (photos), 1 = Clips (videos), 2 = Reposts

  List<Post> _pinned = const [];
  List<Post>? _reposts;
  bool _repostLoading = false;
  Object? _repostError;

  Future<void> _loadPinned() async {
    try {
      final list = await PostService.instance.pinnedPosts(widget.uid);
      if (mounted) setState(() => _pinned = list);
    } catch (_) {
      // without pins the profile simply shows the newest first
    }
  }

  Future<void> _loadReposts() async {
    setState(() {
      _repostLoading = true;
      _repostError = null;
    });
    try {
      final list = await PostService.instance.repostedPosts(widget.uid);
      if (mounted) setState(() => _reposts = list);
    } catch (e) {
      if (mounted) setState(() => _repostError = e);
    } finally {
      if (mounted) setState(() => _repostLoading = false);
    }
  }

  bool get _isMe => widget.uid == UserService.instance.myUid;

  @override
  void initState() {
    super.initState();
    _pager.loadMore();
    _loadPinned();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 500) {
        _pager.loadMore();
      }
    });
    AppEvents.feedRefresh.addListener(_onRefresh);
  }

  void _onRefresh() {
    _pager.refresh();
    _loadPinned();
    if (_reposts != null) _loadReposts();
  }

  @override
  void dispose() {
    AppEvents.feedRefresh.removeListener(_onRefresh);
    _scroll.dispose();
    _pager.dispose();
    super.dispose();
  }

  /// Opens the story editor (pick a photo or video, add text, stickers, music...).
  Future<void> _addStory() async {
    final done = await startStoryFlow(context);
    if (done && mounted) AppEvents.refreshFeed();
  }

  /// Tapping the picture plays the person's moment; my own picture without a moment
  /// starts a new one.
  bool _opening = false;

  Future<void> _tapAvatar(AppUser user) async {
    if (_opening) return;
    _opening = true;
    try {
      final shown = await openMomentsOf(context, user.uid);
      if (shown || !mounted) return;
      if (_isMe) {
        await _addStory();
      } else {
        noMomentNote(context, user.username);
      }
    } finally {
      _opening = false;
    }
  }

  void _openSettings(AppUser me) => openScreen(context, SettingsScreen(me: me));

  /// Opens the share screen: QR code, link, username and a Share button.
  Future<void> _shareProfile(AppUser user) async {
    openScreen(context, ShareProfileScreen(user: user));
  }

  Future<void> _moreMenu(AppUser user) async {
    final blocked = SafetyService.instance.isBlocked(user.uid);
    final pick = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.ios_share_rounded),
              title: Text(ctx.tr('Share profile')),
              onTap: () => Navigator.pop(ctx, 'share'),
            ),
            ListTile(
              key: const ValueKey('blockMenu'),
              leading: Icon(
                blocked ? Icons.lock_open_rounded : Icons.block_rounded,
                color: blocked ? null : AppTheme.coral,
              ),
              title: Text(
                blocked ? ctx.tr('Unblock') : ctx.tr('Block'),
                style: TextStyle(color: blocked ? null : AppTheme.coral),
              ),
              onTap: () => Navigator.pop(ctx, 'block'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (pick == 'share') {
      await _shareProfile(user);
      return;
    }
    if (pick == 'block') {
      await toggleBlock(context, user);
      if (mounted) setState(() {});
    }
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

  /// Someone else's profile whose posts I may not see (private and not followed, or blocked).
  bool _locked(AppUser user) =>
      !_isMe &&
      (SafetyService.instance.isBlocked(user.uid) ||
          (user.isPrivate &&
              !SafetyService.instance.following.contains(user.uid)));

  Widget _body(BuildContext context, AppUser user) {
    return ListenableBuilder(
      listenable: _pager,
      builder: (context, _) {
        final pinnedIds = {for (final p in _pinned) p.id};
        final shown = <Post>[
          for (final p in _pinned)
            if (p.isClip == (_tab == 1)) p,
          for (final p in _pager.posts)
            if (p.isClip == (_tab == 1) && !pinnedIds.contains(p.id)) p,
        ];
        // a tab with few items on the first pages: keep loading until it has some
        if (!_locked(user) &&
            _tab < 2 &&
            shown.length < 9 &&
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
              if (!_locked(user))
                SliverToBoxAdapter(
                  child: HighlightsRow(
                    key: ValueKey('hlRow_${user.uid}'),
                    uid: user.uid,
                    username: user.username,
                    photoUrl: user.photoUrl,
                    isMe: _isMe,
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                  child: _ProfileTabs(
                    index: _tab,
                    onChanged: (i) {
                      setState(() => _tab = i);
                      if (i == 2 && _reposts == null && !_repostLoading) {
                        _loadReposts();
                      }
                    },
                  ),
                ),
              ),
              if (_tab == 2 && !_locked(user))
                ..._repostSlivers()
              else if (_pager.initialLoading)
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
              else if (_locked(user))
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: EmptyState(
                      key: const ValueKey('lockedProfile'),
                      icon: SafetyService.instance.isBlocked(user.uid)
                          ? Icons.block_rounded
                          : Icons.lock_outline_rounded,
                      title: SafetyService.instance.isBlocked(user.uid)
                          ? 'You blocked this account'
                          : 'This account is private',
                      subtitle: SafetyService.instance.isBlocked(user.uid)
                          ? 'Unblock it from the three dots to see its posts.'
                          : 'Request to follow to see their posts and clips.',
                    ),
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
                PostGridSliver(posts: shown, showViews: true),
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

  List<Widget> _repostSlivers() {
    final list = _reposts;
    if (_repostError != null && list == null) {
      return [
        SliverToBoxAdapter(
          child: ErrorState(error: _repostError!, onRetry: _loadReposts),
        ),
      ];
    }
    if (list == null || _repostLoading && list.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: Padding(padding: EdgeInsets.all(40), child: CenteredLoader()),
        ),
      ];
    }
    if (list.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: EmptyState(
              key: const ValueKey('noReposts'),
              icon: Icons.repeat_rounded,
              title: _isMe ? 'Nothing reposted yet' : 'No reposts yet',
              subtitle: _isMe
                  ? 'Tap Repost on a post or clip to keep it here.'
                  : null,
            ),
          ),
        ),
      ];
    }
    return [PostGridSliver(posts: list, showViews: false)];
  }

  Widget _header(BuildContext context, AppUser user) {
    final top = MediaQuery.of(context).padding.top;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---- banner with aurora colours + floating avatar
        SizedBox(
          height: 120 + top + 44,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: Container(
                  height: 120 + top,
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
                        key: const ValueKey('settingsButton'),
                        icon: Icons.settings_rounded,
                        tooltip: context.tr('Settings'),
                        onTap: () => _openSettings(user),
                      )
                    else if (!_isMe)
                      GlassIconButton(
                        key: const ValueKey('profileMore'),
                        icon: Icons.more_horiz_rounded,
                        onTap: () => _moreMenu(user),
                      ),
                  ],
                ),
              ),
              Positioned(
                left: 30,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: context.bg,
                    shape: BoxShape.circle,
                  ),
                  child: GestureDetector(
                    key: const ValueKey('profileAvatar'),
                    onTap: () => _tapAvatar(user),
                    child: UserAvatar(
                      url: user.photoUrl,
                      name: user.username,
                      radius: 42,
                      uid: user.uid,
                    ),
                  ),
                ),
              ),
              if (_isMe)
                Positioned(
                  left: 30 + 4 + 84 - 24,
                  bottom: 4,
                  child: GestureDetector(
                    key: const ValueKey('avatarPlus'),
                    onTap: _addStory,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: context.bg,
                        shape: BoxShape.circle,
                      ),
                      child: Container(
                        decoration: const BoxDecoration(
                          color: AppTheme.volt,
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(3),
                        child: const Icon(
                          Icons.add_rounded,
                          size: 20,
                          color: AppTheme.ink,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      user.fullName.isNotEmpty ? user.fullName : user.username,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -1,
                      ),
                    ),
                  ),
                  if (user.verified)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(
                        Icons.verified_rounded,
                        key: ValueKey('verifiedBadge'),
                        color: Color(0xFF3D9BFF),
                        size: 24,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text('@${user.username}', style: TextStyle(color: context.muted)),
              if (user.bio.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  user.bio,
                  key: const ValueKey('profileBio'),
                  style: maybeAppFont(
                    user.bioFont,
                    const TextStyle(fontSize: 15, height: 1.35),
                  ),
                ),
              ],
              if (user.links.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < user.links.length; i++)
                      _LinkChip(url: user.links[i], name: user.linkLabel(i)),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  _Stat(label: context.tr('Posts'), value: user.postsCount),
                  _Stat(
                    label: context.tr('Followers'),
                    value: user.followersCount,
                    onTap: () => openScreen(
                      context,
                      FollowListScreen(uid: user.uid, followers: true),
                    ),
                  ),
                  _Stat(
                    label: context.tr('Following'),
                    value: user.followingCount,
                    onTap: () => openScreen(
                      context,
                      FollowListScreen(uid: user.uid, followers: false),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_isMe)
                Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            key: const ValueKey('editProfileButton'),
                            style: _smallButton,
                            onPressed: () => openScreen(
                              context,
                              EditProfileScreen(user: user),
                            ),
                            child: Text(context.tr('Edit profile')),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            key: const ValueKey('shareProfileButton'),
                            style: _smallButton,
                            onPressed: () => _shareProfile(user),
                            child: Text(context.tr('Share profile')),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Your numbers for the whole account. One post's numbers open by holding it.
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        key: const ValueKey('dashboardButton'),
                        style: _smallButton,
                        onPressed: () =>
                            openScreen(context, const AnalyticsScreen()),
                        icon: const Icon(Icons.insights_rounded, size: 18),
                        label: Text(context.tr('Dashboard')),
                      ),
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 38,
                        child: FollowButton(
                          uid: user.uid,
                          isPrivate: user.isPrivate,
                          style: _smallButton,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SizedBox(
                        height: 38,
                        child: OutlinedButton.icon(
                          key: const ValueKey('messageButton'),
                          style: _smallButton,
                          onPressed: () => openScreen(
                            context,
                            ChatScreen(otherUid: user.uid, user: user),
                          ),
                          icon: const Icon(
                            Icons.chat_bubble_outline_rounded,
                            size: 18,
                          ),
                          label: const Text('Message'),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Compact buttons of the profile (the theme's buttons are tall).
final ButtonStyle _smallButton = ButtonStyle(
  minimumSize: const WidgetStatePropertyAll(Size(0, 38)),
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
  textStyle: const WidgetStatePropertyAll(
    TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
  ),
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
  ),
);

/// Number over a label, no box around it.
class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.onTap});
  final String label;
  final int value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$value',
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.4,
                ),
              ),
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

/// Posts | Clips as two icons with an underline (small, like the rest of the profile).
class _ProfileTabs extends StatelessWidget {
  const _ProfileTabs({required this.index, required this.onChanged});
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget tab(int i, IconData icon, String label) {
      final on = index == i;
      return Expanded(
        child: GestureDetector(
          key: ValueKey('profileTab$i'),
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(i),
          child: Container(
            height: 42,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: on ? context.accentInk : context.hairline,
                  width: on ? 2.5 : 1,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: on ? context.accentInk : context.muted,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13.5,
                      color: on ? null : context.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        tab(0, Icons.grid_view_rounded, context.tr('Posts')),
        tab(1, Icons.smart_display_rounded, context.tr('Clips')),
        tab(2, Icons.repeat_rounded, context.tr('Reposts')),
      ],
    );
  }
}

/// A tappable link on a profile.
class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.url, this.name = ''});
  final String url;

  /// The name the owner gave the link ('' = show the web address).
  final String name;

  String get _label => name.isNotEmpty ? name : _address;

  String get _address => url
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
