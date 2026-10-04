import 'package:flutter/material.dart';

import '../../core/app_events.dart';
import '../../core/theme.dart';
import '../../services/user_service.dart';
import '../../widgets/glass.dart';
import '../feed/feed_screen.dart';
import '../post/create_post_screen.dart';
import '../profile/profile_screen.dart';
import '../reels/reels_screen.dart';
import '../search/search_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  Future<void> _createPost() async {
    final posted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (_) => const CreatePostScreen(),
      ),
    );
    if (posted == true) {
      AppEvents.refreshFeed();
      if (mounted) setState(() => _index = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      const FeedScreen(),
      const SearchScreen(),
      ReelsScreen(
        active: _index == 2,
        onBack: () => setState(() => _index = 0),
      ),
      ProfileScreen(uid: UserService.instance.myUid, isTab: true),
    ];
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;

    // Back from any other tab goes to Discover first; only then exits the app.
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _index = 0);
      },
      child: Scaffold(
        body: Stack(
          children: [
            IndexedStack(index: _index, children: tabs),
            // Clips is full screen: no bottom bar there (it has its own back button).
            if (!keyboardOpen && _index != 2)
              Positioned(
                left: 16,
                right: 16,
                bottom: 8 + bottomInset,
                child: Center(
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Row(
                      children: [
                        Expanded(
                          child: Glass(
                            radius: 22,
                            blur: 22,
                            opacity: 0.78,
                            padding: const EdgeInsets.all(3),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                _NavItem(
                                  icon: Icons.home_outlined,
                                  activeIcon: Icons.home_rounded,
                                  label: 'Discover',
                                  selected: _index == 0,
                                  onTap: () => setState(() => _index = 0),
                                ),
                                _NavItem(
                                  icon: Icons.explore_outlined,
                                  activeIcon: Icons.explore_rounded,
                                  label: 'Explore',
                                  selected: _index == 1,
                                  onTap: () => setState(() => _index = 1),
                                ),
                                _NavItem(
                                  icon: Icons.play_circle_outline_rounded,
                                  activeIcon: Icons.play_circle_rounded,
                                  label: 'Clips',
                                  selected: _index == 2,
                                  onTap: () => setState(() => _index = 2),
                                ),
                                _NavItem(
                                  icon: Icons.person_outline_rounded,
                                  activeIcon: Icons.person_rounded,
                                  label: 'Me',
                                  selected: _index == 3,
                                  onTap: () => setState(() => _index = 3),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: _createPost,
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              gradient: AppTheme.voltGradient,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: AppTheme.volt.withValues(alpha: 0.4),
                                  blurRadius: 14,
                                  offset: const Offset(0, 5),
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.add_rounded,
                              size: 26,
                              color: AppTheme.ink,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        height: 38,
        padding: EdgeInsets.symmetric(horizontal: selected ? 12 : 10),
        decoration: BoxDecoration(
          color: selected ? AppTheme.volt : Colors.transparent,
          borderRadius: BorderRadius.circular(19),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? activeIcon : icon,
              size: 22,
              color: selected
                  ? AppTheme.ink
                  : Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              child: selected
                  ? Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        label,
                        style: const TextStyle(
                          color: AppTheme.ink,
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}
