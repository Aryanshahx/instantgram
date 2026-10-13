import 'package:flutter/material.dart';

import '../../core/services/deep_links.dart';
import '../../core/services/media_prefetch.dart';
import '../profile/presentation/open_username.dart';
import '../profile/data/famous_index.dart';
import '../reels/data/clips_warmup.dart';

import '../../core/services/app_settings.dart';
import '../../core/services/content_filter.dart';
import '../../core/services/usage_tracker.dart';
import '../stories/data/moments_index.dart';

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
  AppLifecycleListener? _life;

  @override
  void initState() {
    super.initState();
    AppSettings.instance.load();
    ContentFilter.instance.start(widget.uid);
    MomentsIndex.instance.start();
    FamousIndex.instance.start();
    ClipsWarmup.instance.start();
    // app in the background -> free the ready video players
    _life = AppLifecycleListener(onHide: VideoPool.instance.clear);
    UsageTracker.instance
      ..onLimitReached = _limitReached
      ..start();
    // instantgram://u/<username> (shared profile links + QR codes)
    DeepLinks.instance.start((name) {
      if (mounted) openUsername(context, name);
    });
  }

  @override
  void dispose() {
    UsageTracker.instance
      ..onLimitReached = null
      ..stop();
    _life?.dispose();
    DeepLinks.instance.stop();
    ClipsWarmup.instance.stop();
    FamousIndex.instance.stop();
    VideoPool.instance.clear();
    MomentsIndex.instance.stop();
    ContentFilter.instance.stop();
    super.dispose();
  }

  void _limitReached() {
    if (!mounted) return;
    final mins = AppSettings.instance.dailyLimitMinutes.value;
    showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.hourglass_bottom_rounded, size: 36),
        title: const Text('Time for a break?'),
        content: Text(
          "You've used InstantGram for $mins minutes today — your daily "
          'reminder. You can change it in Settings → Manage time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

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
