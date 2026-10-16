import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/services/calls.dart';
import '../../core/services/chat_prefs.dart';
import '../../core/services/deep_links.dart';
import '../../core/services/media_prefetch.dart';
import '../../core/services/presence.dart';
import '../chats/data/chat_receipts.dart';
import '../profile/data/user_repository.dart';
import '../profile/presentation/open_username.dart';
import '../profile/data/famous_index.dart';
import '../reels/data/clips_warmup.dart';

import '../../core/services/app_settings.dart';
import '../../core/services/content_filter.dart';
import '../../core/services/hyper_feed.dart';
import '../../core/services/hyper_intelligence.dart';
import '../../core/services/usage_tracker.dart';
import '../stories/data/moments_index.dart';

import '../chats/presentation/chats_screen.dart';
import '../feed/presentation/home_screen.dart';
import '../post/data/upload_queue.dart';
import '../post/presentation/create_sheet.dart';
import '../profile/presentation/profile_screen.dart';
import '../reels/presentation/clips_screen.dart';
import '../search/presentation/explore_screen.dart';
import 'push_router.dart';
import 'widgets/floating_nav_bar.dart';
import '../../core/config/app_info.dart';
import '../../core/services/account_status.dart';
import '../../core/theme/app_colors.dart';
import '../settings/presentation/settings_screen.dart' show signOutEverything;

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
  StreamSubscription<UploadTask>? _shared;

  @override
  void initState() {
    super.initState();
    AppSettings.instance.load();
    ContentFilter.instance.start(widget.uid);
    // v0.18: Hyper Intelligence (sensitive setting + under 18)
    HyperIntelligence.instance.start();
    // v0.19: Hyper Intelligence feed (learns on the phone)
    HyperFeed.instance
      ..uploader = UserRepository.instance.saveInterests
      ..downloader = UserRepository.instance.loadInterests;
    HyperFeed.instance.start(widget.uid);
    MomentsIndex.instance.start();
    FamousIndex.instance.start();
    ClipsWarmup.instance.start();
    // app in the background -> free the ready video players
    _life = AppLifecycleListener(onHide: VideoPool.instance.clear);
    UsageTracker.instance
      ..onLimitReached = _limitReached
      ..start();
    // v0.8: posts that were still uploading go on (also after a restart)
    UploadQueue.instance.start();
    _shared = UploadQueue.instance.finished.listen(_onShared);
    // instantgram://u/<username> (shared profile links + QR codes)
    DeepLinks.instance.start((name) {
      if (mounted) openUsername(context, name);
    });
    unawaited(_startCalls());
  }

  /// Voice + video calls (receive calls, open an accepted one), plus
  /// v0.10 "Active now" and message ticks (delivered).
  Future<void> _startCalls() async {
    unawaited(Presence.instance.start(widget.uid));
    ChatReceipts.instance.start(widget.uid);
    // v0.11: pinned / muted chats
    ChatPrefs.instance.start(widget.uid);
    // v0.13: verified badges + blocked accounts (admin website)
    AccountStatus.instance.start(widget.uid, onBanned: _banned);
    try {
      final me = await UserRepository.instance.meCached();
      await Calls.instance.signIn(
        uid: widget.uid,
        username: me.username,
        photoUrl: me.photoUrl,
      );
      if (mounted) await Calls.instance.openAcceptedCall();
      // v0.11: tapped notifications open the chat / muted call
      if (mounted) await PushRouter.instance.start();
    } catch (e) {
      debugPrint('calls: $e');
    }
  }

  /// v0.13: the admin blocked this account -> tell the user, log out.
  Future<void> _banned() async {
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.block, size: 36, color: AppColors.like),
        title: const Text('Account blocked'),
        content: const Text(
          'This account was blocked for breaking the InstantGram rules. '
          'If you think this is a mistake, email ${AppInfo.supportEmail}.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('banned-ok'),
            onPressed: () => Navigator.pop(d),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    AccountStatus.instance.stop();
    await signOutEverything();
  }

  void _onShared(UploadTask t) {
    if (!mounted) return;
    final n = t.items.length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          t.isMoment
              ? (n > 1 ? '$n moments shared ✨' : 'Moment shared ✨')
              : t.kind == UploadTask.clip
              ? 'Clip shared 🎬'
              : 'Post shared 🎉',
        ),
      ),
    );
  }

  @override
  void dispose() {
    _shared?.cancel();
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
    AccountStatus.instance.stop();
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
