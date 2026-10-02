import 'package:flutter/material.dart';

import '../../core/app_events.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../services/post_pager.dart';
import '../../services/post_service.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/brand_logo.dart';
import '../../widgets/pill_tabs.dart';
import '../../widgets/post_card.dart';
import '../../widgets/state_views.dart';
import '../../widgets/stories_bar.dart';
import '../profile/profile_screen.dart';

class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  late final PostPager _discover =
      PostPager(PostService.instance.latestQuery, pageSize: 8);
  late final Stream<AppUser?> _me =
      UserService.instance.watchUser(UserService.instance.myUid);

  PostPager? _following;
  bool _followingLoading = false;
  bool _noFollowing = false;
  Object? _followingError;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _discover.loadMore();
    AppEvents.feedRefresh.addListener(_onRefresh);
  }

  @override
  void dispose() {
    AppEvents.feedRefresh.removeListener(_onRefresh);
    _discover.dispose();
    _following?.dispose();
    super.dispose();
  }

  void _onRefresh() {
    _discover.refresh();
    if (_tab == 1 || _following != null) _loadFollowing();
  }

  Future<void> _loadFollowing() async {
    setState(() {
      _followingLoading = true;
      _followingError = null;
    });
    try {
      final me = UserService.instance.myUid;
      final ids = await UserService.instance.followingIds();
      if (!mounted) return;
      _following?.dispose();
      _following = null;
      if (ids.isEmpty) {
        setState(() {
          _noFollowing = true;
          _followingLoading = false;
        });
        return;
      }
      // Firestore `whereIn` accepts up to 30 values.
      final authors = <String>[me, ...ids].take(30).toList();
      final pager = PostPager(
        () => PostService.instance.followingQuery(authors),
        pageSize: 8,
      )..loadMore();
      setState(() {
        _following = pager;
        _noFollowing = false;
        _followingLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _followingError = e;
          _followingLoading = false;
        });
      }
    }
  }

  void _setTab(int i) {
    if (i == _tab) return;
    setState(() => _tab = i);
    if (i == 1 && _following == null && !_followingLoading && !_noFollowing) {
      _loadFollowing();
    }
  }

  @override
  Widget build(BuildContext context) {
    final header = _FeedHeader(me: _me, tab: _tab, onTab: _setTab);
    return SafeArea(
      bottom: false,
      child: _tab == 0
          ? PagedPostList(
              pager: _discover,
              header: header,
              onRefresh: () async {
                // Reloads posts, moments and the Following tab together.
                AppEvents.refreshFeed();
                while (_discover.loading) {
                  await Future<void>.delayed(const Duration(milliseconds: 100));
                }
              },
              empty: const EmptyState(
                icon: Icons.bolt_rounded,
                title: 'Nothing here yet',
                subtitle: 'Tap the + button to share the first photo or clip.',
              ),
            )
          : _followingBody(header),
    );
  }

  Widget _followingBody(Widget header) {
    Widget wrap(Widget child) => RefreshIndicator(
          onRefresh: _loadFollowing,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [header, child, const SizedBox(height: kNavSpace)],
          ),
        );

    if (_followingLoading && _following == null) {
      return wrap(const Padding(
        padding: EdgeInsets.only(top: 60),
        child: CenteredLoader(),
      ));
    }
    if (_followingError != null) {
      return wrap(ErrorState(error: _followingError!, onRetry: _loadFollowing));
    }
    if (_noFollowing || _following == null) {
      return wrap(const Padding(
        padding: EdgeInsets.only(top: 30),
        child: EmptyState(
          icon: Icons.group_add_outlined,
          title: 'Follow people to fill this feed',
          subtitle: 'Find friends in Explore. Their posts will land here.',
        ),
      ));
    }
    return PagedPostList(
      pager: _following!,
      header: header,
      onRefresh: _loadFollowing,
      empty: const EmptyState(
        icon: Icons.photo_outlined,
        title: 'Quiet for now',
        subtitle: 'The people you follow have not posted yet.',
      ),
    );
  }
}

class _FeedHeader extends StatelessWidget {
  const _FeedHeader({required this.me, required this.tab, required this.onTab});

  final Stream<AppUser?> me;
  final int tab;
  final ValueChanged<int> onTab;

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Row(
            children: [
              const BrandLogo(size: 24),
              const Spacer(),
              StreamBuilder<AppUser?>(
                stream: me,
                builder: (context, snap) {
                  final u = snap.data;
                  return GestureDetector(
                    onTap: u == null
                        ? null
                        : () => openScreen(context, ProfileScreen(uid: u.uid)),
                    child: UserAvatar(
                        url: u?.photoUrl ?? '',
                        name: u?.username ?? '',
                        radius: 19),
                  );
                },
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
          child: StreamBuilder<AppUser?>(
            stream: me,
            builder: (context, snap) {
              final u = snap.data;
              final name = (u == null)
                  ? ''
                  : (u.fullName.trim().isNotEmpty
                      ? u.fullName.trim().split(' ').first
                      : u.username);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_greeting, style: TextStyle(color: context.muted, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(
                    name.isEmpty ? "What's new?" : "$name, what's new?",
                    style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -1,
                        height: 1.1),
                  ),
                ],
              );
            },
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: Text('Moments',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        ),
        const StoriesBar(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
          child: PillTabs(
            labels: const ['Discover', 'Following'],
            icons: const [Icons.auto_awesome_rounded, Icons.people_alt_rounded],
            index: tab,
            onChanged: onTab,
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------ shared list UI

class PagedPostList extends StatefulWidget {
  const PagedPostList({
    super.key,
    required this.pager,
    required this.onRefresh,
    required this.empty,
    this.header,
  });

  final PostPager pager;
  final Future<void> Function() onRefresh;
  final Widget empty;
  final Widget? header;

  @override
  State<PagedPostList> createState() => _PagedPostListState();
}

class _PagedPostListState extends State<PagedPostList> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) {
        widget.pager.loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _footer(BuildContext context) {
    final pager = widget.pager;
    Widget body;
    if (pager.loading) {
      body = const Padding(
        padding: EdgeInsets.all(28),
        child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
      );
    } else if (pager.error != null && pager.posts.isEmpty) {
      body = ErrorState(error: pager.error!, onRetry: pager.retry);
    } else if (pager.error != null) {
      body = Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: TextButton(onPressed: pager.retry, child: const Text('Retry')),
        ),
      );
    } else if (pager.posts.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.only(top: 30),
        child: widget.empty,
      );
    } else {
      body = const SizedBox.shrink();
    }
    return Column(children: [body, const SizedBox(height: kNavSpace)]);
  }

  @override
  Widget build(BuildContext context) {
    final pager = widget.pager;
    return ListenableBuilder(
      listenable: pager,
      builder: (context, _) {
        final hasHeader = widget.header != null;
        final headerCount = hasHeader ? 1 : 0;
        final posts = pager.posts;

        return RefreshIndicator(
          onRefresh: widget.onRefresh,
          child: ListView.builder(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: headerCount + posts.length + 1,
            itemBuilder: (context, i) {
              if (hasHeader && i == 0) return widget.header!;
              final idx = i - headerCount;
              if (idx < posts.length) {
                final post = posts[idx];
                return PostCard(
                  key: ValueKey(post.id),
                  post: post,
                  onDeleted: () => pager.removeById(post.id),
                );
              }
              return _footer(context);
            },
          ),
        );
      },
    );
  }
}
