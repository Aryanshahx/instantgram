import 'package:flutter/material.dart';

import '../../../core/services/media_prefetch.dart';
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
import '../../post/presentation/upload_banner.dart';
import '../../profile/data/famous_index.dart';
import '../../profile/data/user_repository.dart';
import '../../search/presentation/find_people_screen.dart';
import '../../stories/data/moments_index.dart';
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
        builder: (context, fSnap) => ValueListenableBuilder<List<String>>(
          valueListenable: FamousIndex.instance.ids,
          builder: (context, famous, _) => _HomeFeed(
            me: meSnap.data,
            uid: uid,
            following: fSnap.data,
            famous: famous,
          ),
        ),
      ),
    );
  }
}

class _HomeFeed extends StatefulWidget {
  const _HomeFeed({
    required this.me,
    required this.uid,
    required this.following,
    this.famous = const <String>[],
  });

  final UserProfile? me;
  final String uid;
  final List<String>? following;

  /// 10,000+ followers: always in the feed + moments row.
  final List<String> famous;

  @override
  State<_HomeFeed> createState() => _HomeFeedState();
}

class _HomeFeedState extends State<_HomeFeed> {
  Stream<List<Post>>? _stream;
  String _streamKey = '';
  int _refresh = 0;

  /// me + people I follow + famous people.
  List<String>? get _authors {
    final f = widget.following;
    if (f == null) return null;
    return feedAuthors(widget.uid, f, widget.famous);
  }

  /// Same stream until the people change or you pull to refresh
  /// (so the feed doesn't reload on every rebuild).
  Stream<List<Post>>? _feedStream(List<String>? authors) {
    if (authors == null) return null;
    final sorted = [...authors]..sort();
    final key = '${sorted.join(',')}#$_refresh';
    if (key != _streamKey || _stream == null) {
      _streamKey = key;
      _stream = PostRepository.instance.feedFor(authors);
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
    final authors = _authors;
    final Stream<List<Post>>? stream = _feedStream(authors);
    final allowed = <String>{...?authors};
    if (authors != null) MomentsIndex.instance.setAllowed(allowed);

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
          // v0.8: "Sharing your post… 45%" (background uploads)
          const SliverToBoxAdapter(child: UploadBanner()),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: StoryBar(
                key: ValueKey('stories-$_refresh'),
                me: me,
                myUid: uid,
                allowed: allowed,
                onAddStory: () => startCompose(context, ComposeMode.story),
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
                          icon: Icons.people_outline,
                          title: 'Your feed is empty',
                          subtitle:
                              'Follow people to see their posts and moments '
                              'here.',
                        ),
                        Wrap(
                          spacing: 10,
                          children: [
                            FilledButton.icon(
                              key: const ValueKey('feed-find-people'),
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const FindPeopleScreen(),
                                ),
                              ),
                              icon: const Icon(Icons.person_search, size: 18),
                              label: const Text('Find people'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => showCreateSheet(context),
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('Create'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                }
                return SliverList.builder(
                  itemCount: posts.length,
                  itemBuilder: (context, i) {
                    // get the next posts' photos + first video ready
                    MediaPrefetch.instance.ahead(
                      posts,
                      i,
                      images: 2,
                      videos: 1,
                      mixWithOthers: (p) => p.hasMusic,
                    );
                    return PostCard(post: posts[i]);
                  },
                );
              },
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 110)),
        ],
      ),
    );
  }
}
