import 'package:flutter/material.dart';

import '../../core/app_events.dart';
import '../../services/post_pager.dart';
import '../../services/post_service.dart';
import '../../services/user_service.dart';
import '../../widgets/brand_logo.dart';
import '../../widgets/post_card.dart';
import '../../widgets/state_views.dart';
import '../../widgets/stories_bar.dart';

class FeedScreen extends StatelessWidget {
  const FeedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const BrandLogo(size: 28),
          bottom: const TabBar(
            tabs: [Tab(text: 'For you'), Tab(text: 'Following')],
          ),
        ),
        body: const TabBarView(
          children: [_ForYouTab(), _FollowingTab()],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------- For you

class _ForYouTab extends StatefulWidget {
  const _ForYouTab();

  @override
  State<_ForYouTab> createState() => _ForYouTabState();
}

class _ForYouTabState extends State<_ForYouTab>
    with AutomaticKeepAliveClientMixin {
  late final PostPager _pager =
      PostPager(PostService.instance.latestQuery, pageSize: 8);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _pager.loadMore();
    AppEvents.feedRefresh.addListener(_onRefresh);
  }

  void _onRefresh() => _pager.refresh();

  @override
  void dispose() {
    AppEvents.feedRefresh.removeListener(_onRefresh);
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return PagedPostList(
      pager: _pager,
      header: const StoriesBar(),
      onRefresh: () async {
        // Reloads posts, stories and the Following tab together.
        AppEvents.refreshFeed();
        while (_pager.loading) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      },
      empty: const EmptyState(
        icon: Icons.photo_camera_outlined,
        title: 'No posts yet',
        subtitle: 'Tap + to share the first photo or video link.',
      ),
    );
  }
}

// ----------------------------------------------------------------- Following

class _FollowingTab extends StatefulWidget {
  const _FollowingTab();

  @override
  State<_FollowingTab> createState() => _FollowingTabState();
}

class _FollowingTabState extends State<_FollowingTab>
    with AutomaticKeepAliveClientMixin {
  PostPager? _pager;
  Object? _error;
  bool _loading = true;
  bool _noFollowing = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _init();
    AppEvents.feedRefresh.addListener(_init);
  }

  @override
  void dispose() {
    AppEvents.feedRefresh.removeListener(_init);
    _pager?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final me = UserService.instance.myUid;
      final ids = await UserService.instance.followingIds();
      if (!mounted) return;
      _pager?.dispose();
      _pager = null;
      if (ids.isEmpty) {
        setState(() {
          _noFollowing = true;
          _loading = false;
          _error = null;
        });
        return;
      }
      // Firestore `whereIn` accepts up to 30 values.
      final authors = <String>[me, ...ids].take(30).toList();
      final pager = PostPager(
        () => PostService.instance.followingQuery(authors),
        pageSize: 8,
      );
      pager.loadMore();
      setState(() {
        _pager = pager;
        _noFollowing = false;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const CenteredLoader();
    if (_error != null) {
      return ErrorState(error: _error!, onRetry: _init);
    }
    if (_noFollowing || _pager == null) {
      return RefreshIndicator(
        onRefresh: _init,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 120),
            EmptyState(
              icon: Icons.people_outline,
              title: "You're not following anyone yet",
              subtitle: 'Use Search to find people. Their posts will show up here.',
            ),
          ],
        ),
      );
    }
    return PagedPostList(
      pager: _pager!,
      onRefresh: _init,
      empty: const EmptyState(
        icon: Icons.photo_outlined,
        title: 'Nothing here yet',
        subtitle: 'People you follow have not posted anything.',
      ),
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

  @override
  Widget build(BuildContext context) {
    final pager = widget.pager;
    return ListenableBuilder(
      listenable: pager,
      builder: (context, _) {
        if (pager.initialLoading) return const CenteredLoader();
        if (pager.error != null && pager.posts.isEmpty) {
          return ErrorState(error: pager.error!, onRetry: pager.retry);
        }

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
              // footer
              if (pager.loading) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2.5)),
                );
              }
              if (pager.error != null) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: TextButton(
                        onPressed: pager.retry, child: const Text('Retry')),
                  ),
                );
              }
              if (posts.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: widget.empty,
                );
              }
              return const SizedBox(height: 24);
            },
          ),
        );
      },
    );
  }
}
