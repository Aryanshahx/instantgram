import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/ig_buttons.dart';
import '../../../shared/widgets/net_image.dart';
import '../../auth/data/auth_service.dart';
import '../../post/presentation/create_sheet.dart';
import '../data/user_repository.dart';
import 'edit_profile_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key, required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UserProfile?>(
      stream: UserRepository.instance.watchUser(uid),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final authUser = FirebaseAuth.instance.currentUser;
        final profile =
            snap.data ??
            UserProfile(
              uid: uid,
              name: authUser?.displayName ?? 'New user',
              username: (authUser?.email ?? 'user').split('@').first,
              email: authUser?.email ?? '',
            );
        return ProfileView(profile: profile);
      },
    );
  }
}

class ProfileView extends StatefulWidget {
  const ProfileView({super.key, required this.profile});

  final UserProfile profile;

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this)
    ..addListener(() => setState(() {}));

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _snack(String msg) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _shareProfile() async {
    final link = '${AppConstants.profileLinkBase}${widget.profile.username}';
    await Clipboard.setData(ClipboardData(text: link));
    _snack('Profile link copied: $link');
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit profile'),
              onTap: () {
                Navigator.pop(ctx);
                _editProfile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About InstantGram'),
              onTap: () {
                Navigator.pop(ctx);
                showAboutDialog(
                  context: context,
                  applicationName: AppConstants.appName,
                  applicationLegalese: '© HyperTech Labs',
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.logout, color: AppColors.like),
              title: const Text(
                'Log out',
                style: TextStyle(color: AppColors.like),
              ),
              onTap: () {
                Navigator.pop(ctx);
                AuthService.instance.signOut();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _editProfile() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditProfileScreen(profile: widget.profile),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    return NestedScrollView(
      headerSliverBuilder: (context, _) => [
        SliverToBoxAdapter(
          child: _Header(
            profile: p,
            onSettings: _openSettings,
            onEdit: _editProfile,
            onShare: _shareProfile,
            onDashboard: () => _snack('Dashboard is coming soon 📊'),
            onAddPhoto: () => _snack('Photo upload is coming next (Tigris)'),
            onNewHighlight: () => showCreateSheet(context),
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
                fontSize: 15,
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
      body: TabBarView(
        controller: _tabs,
        children: const [
          _TabEmpty(
            icon: Icons.photo_camera_outlined,
            title: 'No posts yet',
            subtitle: 'Tap + to share your first photo.',
          ),
          _TabEmpty(
            icon: Icons.smart_display_outlined,
            title: 'No clips yet',
            subtitle: 'Your short videos will appear here.',
          ),
          _TabEmpty(
            icon: Icons.repeat,
            title: 'No reposts yet',
            subtitle: 'Posts you repost will appear here.',
          ),
        ],
      ),
    );
  }

  Widget _tab(int i, IconData icon, String label) {
    final selected = _tabs.index == i;
    return Tab(
      height: 56,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 22,
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

class _Header extends StatelessWidget {
  const _Header({
    required this.profile,
    required this.onSettings,
    required this.onEdit,
    required this.onShare,
    required this.onDashboard,
    required this.onAddPhoto,
    required this.onNewHighlight,
  });

  final UserProfile profile;
  final VoidCallback onSettings;
  final VoidCallback onEdit;
  final VoidCallback onShare;
  final VoidCallback onDashboard;
  final VoidCallback onAddPhoto;
  final VoidCallback onNewHighlight;

  static const double _coverHeight = 200;
  static const double _avatarSize = 104;

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    final p = profile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Cover + avatar
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
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(36),
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
              Positioned(
                right: 28,
                top: topPad + 12,
                child: Material(
                  color: Colors.black.withValues(alpha: 0.45),
                  shape: const CircleBorder(),
                  child: IconButton(
                    tooltip: 'Settings',
                    onPressed: onSettings,
                    icon: const Icon(Icons.settings, color: Colors.white),
                  ),
                ),
              ),
              Positioned(
                left: 34,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: AppColors.background,
                    shape: BoxShape.circle,
                  ),
                  child: Avatar(
                    url: p.photoUrl,
                    name: p.name,
                    size: _avatarSize,
                    showPlus: true,
                    onPlusTap: onAddPhoto,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(26, 18, 26, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                p.name.isEmpty ? p.username : p.name,
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '@${p.username}',
                style: const TextStyle(
                  fontSize: 16,
                  color: AppColors.textSecondary,
                ),
              ),
              if (p.bio.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(p.bio, style: const TextStyle(fontSize: 17, height: 1.35)),
              ],
              if (p.website.isNotEmpty) ...[
                const SizedBox(height: 14),
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
              const SizedBox(height: 24),
              Row(
                children: [
                  _Stat(value: p.postsCount, label: 'Posts'),
                  _Stat(value: p.followersCount, label: 'Followers'),
                  _Stat(value: p.followingCount, label: 'Following'),
                ],
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: IgPrimaryButton(
                      label: 'Edit profile',
                      height: 48,
                      onPressed: onEdit,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: IgOutlineButton(
                      label: 'Share profile',
                      height: 48,
                      onPressed: onShare,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              IgOutlineButton(
                label: 'Dashboard',
                icon: Icons.auto_graph,
                height: 48,
                onPressed: onDashboard,
              ),
              const SizedBox(height: 22),
              _NewHighlight(onTap: onNewHighlight),
              const SizedBox(height: 16),
            ],
          ),
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
      shape: StadiumBorder(side: BorderSide(color: AppColors.border)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link, color: AppColors.lime, size: 22),
              const SizedBox(width: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: Text(
                  display,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
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
  const _Stat({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            compactCount(value),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              fontSize: 15,
              color: AppColors.textSecondary,
            ),
          ),
        ],
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
            width: 74,
            height: 74,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF2D3035),
              border: Border.all(color: const Color(0xFF808186), width: 2),
            ),
            child: const Icon(Icons.add, size: 34),
          ),
          const SizedBox(height: 8),
          const Text(
            'New',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _TabEmpty extends StatelessWidget {
  const _TabEmpty({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 110),
      child: EmptyState(icon: icon, title: title, subtitle: subtitle),
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
