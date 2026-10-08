import 'package:flutter/material.dart';

import '../../core/app_events.dart';
import '../../core/l10n.dart';
import '../../core/ui.dart';
import '../../services/app_prefs.dart';
import '../../services/safety_service.dart';
import '../../services/presence_service.dart';
import '../../services/usage_tracker.dart';
import '../../services/auth_service.dart';
import '../../services/call_service.dart';
import '../../services/chat_service.dart';
import '../../services/push_service.dart';
import '../../services/user_service.dart';
import '../../widgets/app_nav_bar.dart';
import '../activity/activity_screen.dart';
import '../call/incoming_call_screen.dart';
import '../chat/chat_screen.dart';
import '../chat/inbox_screen.dart';
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
  /// 0 Discover, 1 Explore, 2 Clips, 3 Chats, 4 Me
  int _index = 0;
  String _lastCallId = '';

  @override
  void initState() {
    super.initState();
    ChatService.instance
        .start(); // keeps the unread dot on the Chats tab up to date
    AuthService.instance
        .linkLoginEmail(); // lets the username be used to log in
    AppEvents.searchRequest.addListener(_onSearchRequest);
    CallService.instance
        .start(); // rings when someone calls (while the app is open)
    CallService.instance.incoming.addListener(_onIncomingCall);
    SafetyService.instance.load().then((_) {
      if (mounted) AppEvents.refreshFeed(); // hide posts of people I blocked
    });
    UsageTracker.instance.start();
    PresenceService.instance.start();
    UsageTracker.instance.limitReached.addListener(_onLimit);
    _syncProfile();
    PushService.instance.opened.addListener(_onPushTap);
    PushService.instance.shown.addListener(_onPushShown);
    PushService.instance.start().then((_) => _onPushTap());
  }

  /// A notification came while the app is open: a short banner (calls ring by themselves).
  void _onPushShown() {
    final n = PushService.instance.shown.value;
    if (n == null || !mounted) return;
    PushService.instance.shown.value = null;
    if (n.type == 'call') return;
    showToast(context, n.body.isEmpty ? n.title : '${n.title}: ${n.body}');
  }

  /// A push notification was tapped: open that chat, or Notifications. (A call opens the
  /// ringing screen by itself.)
  void _onPushTap() {
    final d = PushService.instance.opened.value;
    if (d == null || !mounted) return;
    PushService.instance.opened.value = null;
    final from = d['from'] ?? '';
    Widget? screen;
    if (d['type'] == 'message' && from.isNotEmpty) {
      screen = ChatScreen(otherUid: from);
    } else if (d['type'] == 'activity') {
      screen = const ActivityScreen();
    }
    if (screen == null) return;
    final s = screen;
    Navigator.of(
      context,
    ).push<void>(MaterialPageRoute<void>(builder: (_) => s));
  }

  /// Remembers this account on the phone and takes the language saved on the profile.
  Future<void> _syncProfile() async {
    try {
      final me = await UserService.instance.getUser(UserService.instance.myUid);
      if (me == null) return;
      AppPrefs.instance.rememberAccount(
        SavedAccount(
          uid: me.uid,
          username: me.username,
          photoUrl: me.photoUrl,
          email: AuthService.instance.currentUser?.email ?? '',
        ),
      );
      if (me.language.isNotEmpty && me.language != Language.instance.value) {
        Language.instance.choose(me.language);
      }
    } catch (_) {
      // best effort
    }
  }

  /// Today's time in the app passed the daily limit (Settings > Manage time).
  void _onLimit() {
    if (!UsageTracker.instance.limitReached.value || !mounted) return;
    UsageTracker.instance.limitReached.value = false;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Daily limit reached'),
        content: Text(
          'You have spent ${AppPrefs.instance.dailyLimitMinutes} minutes in InstantGram today. Time for a break?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Keep going'),
          ),
        ],
      ),
    );
  }

  /// Someone is calling: show the full-screen Accept / Decline.
  void _onIncomingCall() {
    final c = CallService.instance.incoming.value;
    if (c == null || c.id == _lastCallId || !mounted) return;
    if (CallService.instance.busy || !c.isFresh(DateTime.now())) return;
    _lastCallId = c.id;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => IncomingCallScreen(call: c),
      ),
    );
  }

  /// A #hashtag was tapped somewhere: show Explore (the search screen picks the request up).
  void _onSearchRequest() {
    if (AppEvents.searchRequest.value != null && _index != 1) {
      setState(() => _index = 1);
    }
  }

  @override
  void dispose() {
    AppEvents.searchRequest.removeListener(_onSearchRequest);
    CallService.instance.incoming.removeListener(_onIncomingCall);
    UsageTracker.instance.limitReached.removeListener(_onLimit);
    PushService.instance.opened.removeListener(_onPushTap);
    PushService.instance.shown.removeListener(_onPushShown);
    CallService.instance.stop();
    ChatService.instance.stop();
    super.dispose();
  }

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
      const InboxScreen(),
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
            // Tabs that are not on screen keep their state but are switched off (no animations,
            // and no clip playing in the feed while you are somewhere else).
            IndexedStack(
              index: _index,
              children: [
                for (var i = 0; i < tabs.length; i++)
                  TickerMode(enabled: i == _index, child: tabs[i]),
              ],
            ),
            // Clips is full screen: no bottom bar there (it has its own back button).
            if (!keyboardOpen && _index != 2)
              Positioned(
                left: 12,
                right: 12,
                bottom: 8 + bottomInset,
                child: Center(
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: ValueListenableBuilder(
                      valueListenable: ChatService.instance.threads,
                      builder: (context, _, _) => AppNavBar(
                        index: _index,
                        chatDot: ChatService.instance.unreadCount > 0,
                        onSelect: (i) => setState(() => _index = i),
                        onCreate: _createPost,
                      ),
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
