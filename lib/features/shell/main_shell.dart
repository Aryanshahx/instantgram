import 'package:flutter/material.dart';

import '../chats/presentation/chats_screen.dart';
import '../feed/presentation/home_screen.dart';
import '../post/presentation/create_sheet.dart';
import '../profile/presentation/profile_screen.dart';
import '../reels/presentation/clips_screen.dart';
import '../search/presentation/explore_screen.dart';
import 'widgets/floating_nav_bar.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.uid});

  final String uid;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  static const _clipsIndex = 2;

  static const _items = [
    NavItem('Discover', Icons.home_outlined, Icons.home_rounded),
    NavItem('Explore', Icons.explore_outlined, Icons.explore),
    NavItem('Clips', Icons.play_circle_outline, Icons.play_circle),
    NavItem('Chats', Icons.chat_bubble_outline, Icons.chat_bubble),
    NavItem('Me', Icons.person_outline, Icons.person),
  ];

  int _index = 0;

  void _onTap(int i) {
    if (i == _clipsIndex) {
      // Clips open full-screen (like the design).
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const ClipsScreen()));
      return;
    }
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      HomeScreen(uid: widget.uid),
      const ExploreScreen(),
      const SizedBox.shrink(), // Clips placeholder (opens as a route)
      const ChatsScreen(),
      ProfileScreen(uid: widget.uid),
    ];

    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _index = 0);
      },
      child: Scaffold(
        extendBody: true,
        body: IndexedStack(index: _index, children: pages),
        bottomNavigationBar: FloatingNavBar(
          items: _items,
          currentIndex: _index,
          onTap: _onTap,
          onCreate: () => showCreateSheet(context),
        ),
      ),
    );
  }
}
