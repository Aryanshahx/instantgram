import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/models/post.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/ig_logo.dart';
import '../../notifications/data/notification_repository.dart';
import '../../notifications/presentation/notifications_screen.dart';
import '../../post/data/post_repository.dart';
import '../../post/presentation/create_sheet.dart';
import '../../profile/data/user_repository.dart';
import 'widgets/post_card.dart';
import 'widgets/story_bar.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UserProfile?>(
      stream: UserRepository.instance.watchUser(uid),
      builder: (context, meSnap) => StreamBuilder<List<String>>(
        stream: UserRepository.instance.followingIds(uid),
        builder: (context, fSnap) {
          final following = fSnap.data;
          return _HomeFeed(me: meSnap.data, uid: uid, following: following);
        },
      ),
    );
  }
}

class _HomeFeed extends StatefulWidget {
  const _HomeFeed({
    required this.me,
    required this.uid,
    required this.following,
  });

  final UserProfile? me;
  final String uid;
  final List<String>? following;

  @override
  State<_HomeFeed> createState() => _HomeFeedState();
}

class _HomeFeedState extends State<_HomeFeed> {
  Stream<List<Post>>? _stream;
  String _streamKey = '';
  int _refresh = 0;

  /// Same stream until the people you follow change or you pull to refresh
  /// (so the feed doesn't reload on every rebuild).
  Stream<List<Post>>? _feedStream(bool discover) {
    final f = widget.following;
    if (f == null) return null;
    final key = '${discover ? 'all' : f.take(29).join(',')}#$_refresh';
    if (key != _streamKey || _stream == null) {
      _streamKey = key;
      _stream = discover
          ? PostRepository.instance.recent(limit: 40)
          : PostRepository.instance.feed([widget.uid, ...f.take(29)]);
    }
    return _stream;
  }

  Future<void> _onRefresh() async {
    setState(() => _refresh++);
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.me;
    final uid = widget.uid;
    final f = widget.following;
    // Nobody followed yet -> show latest posts from everyone.
    final bool discover = f != null && f.isEmpty;
    final Stream<List<Post>>? stream = _feedStream(discover);

    return RefreshIndicator(
      key: const ValueKey('feed-refresh'),
      color: AppColors.lime,
      backgroundColor: AppColors.surface,
      edgeOffset: 72,
      onRefresh: _onRefresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverAppBar(
            floating: true,
            snap: true,
            toolbarHeight: 72,
            centerTitle: true,
            title: const IgLogo(size: 32),
            actions: [
              StreamBuilder<bool>(
                stream: NotificationRepository.instance.hasUnread(),
                builder: (context, s) => IconButton(
                  tooltip: 'Notifications',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const NotificationsScreen(),
                    ),
                  ),
                  icon: Badge(
                    isLabelVisible: s.data ?? false,
                    backgroundColor: AppColors.lime,
                    smallSize: 9,
                    child: const Icon(Icons.notifications_none, size: 28),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: StoryBar(
                key: ValueKey('stories-$_refresh'),
                me: me,
                myUid: uid,
                onAddStory: () => startCompose(context, ComposeMode.story),
              ),
            ),
          ),
          if (discover)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(18, 0, 18, 8),
                child: Text(
                  'Latest from everyone · follow people to fill your feed',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          if (stream == null)
            const SliverToBoxAdapter(child: LoadingView())
          else
            StreamBuilder<List<Post>>(
              stream: stream,
              builder: (context, snap) {
                if (snap.hasError) {
                  return SliverToBoxAdapter(
                    child: ErrorView(error: snap.error),
                  );
                }
                if (!snap.hasData) {
                  return const SliverToBoxAdapter(child: LoadingView());
                }
                final posts = snap.data!;
                if (posts.isEmpty) {
                  return SliverToBoxAdapter(
                    child: Column(
                      children: [
                        const EmptyState(
                          icon: Icons.photo_camera_outlined,
                          title: 'No posts yet',
                          subtitle: 'Share your first photo or clip.',
                        ),
                        FilledButton.icon(
                          onPressed: () => showCreateSheet(context),
                          icon: const Icon(Icons.add),
                          label: const Text('Create'),
                        ),
                      ],
                    ),
                  );
                }
                return SliverList.builder(
                  itemCount: posts.length,
                  itemBuilder: (context, i) => PostCard(post: posts[i]),
                );
              },
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 110)),
        ],
      ),
    );
  }
}
