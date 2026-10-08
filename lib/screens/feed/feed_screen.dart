import 'package:flutter/material.dart';

import '../../core/app_events.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/post_pager.dart';
import '../../services/post_service.dart';
import '../../services/notification_service.dart';
import '../../widgets/brand_logo.dart';
import '../../widgets/post_card.dart';
import '../../widgets/state_views.dart';
import '../../widgets/stories_bar.dart';
import '../activity/activity_screen.dart';

class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  late final PostPager _pager = PostPager(
    PostService.instance.latestQuery,
    pageSize: 8,
    feed: true,
  );

  @override
  void initState() {
    super.initState();
    _pager.loadMore();
    AppEvents.feedRefresh.addListener(_onRefresh);
  }

  @override
  void dispose() {
    AppEvents.feedRefresh.removeListener(_onRefresh);
    _pager.dispose();
    super.dispose();
  }

  void _onRefresh() => _pager.refresh();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: ContentWidth(
        maxWidth: 680,
        child: PagedPostList(
          pager: _pager,
          header: const _FeedHeader(),
          onRefresh: () async {
            // Reloads posts and moments together.
            AppEvents.refreshFeed();
            while (_pager.loading) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
          },
          empty: const EmptyState(
            icon: Icons.bolt_rounded,
            title: 'Nothing here yet',
            subtitle: 'Tap the + button to share the first photo or clip.',
          ),
        ),
      ),
    );
  }
}

class _FeedHeader extends StatelessWidget {
  const _FeedHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Center(child: BrandWordmark(size: 26)),
              // The bell: your activity while the app is open (no push notifications).
              Align(
                alignment: Alignment.centerRight,
                child: StreamBuilder<int>(
                  stream: NotificationService.instance.watchUnread(),
                  builder: (context, snap) {
                    final unread = snap.data ?? 0;
                    return IconButton(
                      key: const ValueKey('activityButton'),
                      tooltip: 'Notifications',
                      icon: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          const Icon(Icons.notifications_none_rounded),
                          if (unread > 0)
                            Positioned(
                              right: -1,
                              top: -1,
                              child: Container(
                                key: const ValueKey('activityDot'),
                                width: 9,
                                height: 9,
                                decoration: const BoxDecoration(
                                  color: AppTheme.coral,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                        ],
                      ),
                      onPressed: () =>
                          openScreen(context, const ActivityScreen()),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        const StoriesBar(),
        const SizedBox(height: 4),
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
    return Column(
      children: [
        body,
        const SizedBox(height: kNavSpace),
      ],
    );
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
                  inline: true,
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
