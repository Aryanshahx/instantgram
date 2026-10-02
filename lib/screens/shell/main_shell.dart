import 'package:flutter/material.dart';

import '../../core/app_events.dart';
import '../../services/user_service.dart';
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
      const SizedBox.shrink(), // "+" opens the create screen instead
      ReelsScreen(active: _index == 3),
      ProfileScreen(uid: UserService.instance.myUid, isTab: true),
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          if (i == 2) {
            _createPost();
          } else {
            setState(() => _index = i);
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined, size: 28),
            selectedIcon: Icon(Icons.home, size: 28),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.search, size: 28),
            selectedIcon: Icon(Icons.search, size: 30),
            label: 'Search',
          ),
          NavigationDestination(
            icon: Icon(Icons.add_box_outlined, size: 28),
            label: 'Post',
          ),
          NavigationDestination(
            icon: Icon(Icons.smart_display_outlined, size: 28),
            selectedIcon: Icon(Icons.smart_display, size: 28),
            label: 'Reels',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline, size: 28),
            selectedIcon: Icon(Icons.person, size: 28),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
