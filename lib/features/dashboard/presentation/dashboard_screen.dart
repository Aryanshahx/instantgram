import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/widgets/async_views.dart';
import '../../insights/post_insights.dart';
import '../../insights/post_insights_screen.dart';
import '../../../shared/widgets/post_grid.dart';
import '../../post/data/post_repository.dart';
import '../../profile/data/user_repository.dart';

/// Loads the Dashboard data (tests replace this).
typedef DashboardLoader = Future<DashboardData> Function();

class DashboardData {
  const DashboardData(this.me, this.posts, this.insights);
  final UserProfile me;
  final List<Post> posts;

  /// Overview / Engagement / Audience over your latest posts.
  final PostInsights insights;
}

/// Real stats for your account: Overview, Engagement and Audience added up
/// from your latest posts and clips, plus your top posts.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.loader});

  final DashboardLoader? loader;

  /// How many of your newest posts are read for audience details.
  static const int detailPosts = 30;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<DashboardData> _future = _load();

  Future<DashboardData> _load() async {
    if (widget.loader != null) return widget.loader!();
    final me = await UserRepository.instance.me();
    final posts = await PostRepository.instance.allByUser(me.uid);
    // v0.20: totals (views, likes, comments ...) from ALL your posts;
    // audience details from the newest 30 (their view docs).
    final all = [...posts]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final latest = all.take(DashboardScreen.detailPosts).toList();
    // all view docs at the same time (fast)
    final docs = await Future.wait(
      latest.map(
        (p) => PostRepository.instance
            .viewDocs(p.id)
            .catchError((Object _) => <Map<String, dynamic>>[]),
      ),
    );
    return DashboardData(me, posts, PostInsights.fromMany(all, docs));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard')),
      body: RefreshIndicator(
        onRefresh: () async {
          setState(() => _future = _load());
          await _future;
        },
        child: FutureBuilder<DashboardData>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) {
              return ListView(children: [ErrorView(error: snap.error)]);
            }
            if (!snap.hasData) return const LoadingView();
            final data = snap.data!;
            final me = data.me;
            final posts = data.posts;
            final clips = posts.where((p) => p.isClip).length;
            final top = [...posts]
              ..sort(
                (a, b) => (b.likesCount + b.commentsCount + b.viewsCount)
                    .compareTo(a.likesCount + a.commentsCount + a.viewsCount),
              );

            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 30),
              children: [
                Row(
                  key: const ValueKey('dash-account'),
                  children: [
                    _Card('Followers', me.followersCount, Icons.people),
                    const SizedBox(width: 8),
                    _Card('Following', me.followingCount, Icons.person_add_alt),
                    const SizedBox(width: 8),
                    _Card(
                      'Posts',
                      posts.length - clips,
                      Icons.grid_view_rounded,
                    ),
                    const SizedBox(width: 8),
                    _Card('Clips', clips, Icons.smart_display),
                  ],
                ),
                const SizedBox(height: 16),
                if (posts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 30),
                    child: Text(
                      'Share your first post or clip to see your insights.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  )
                else ...[
                  ...insightsSections(data.insights),
                  if (posts.length > DashboardScreen.detailPosts) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Numbers come from your newest '
                      '${DashboardScreen.detailPosts} of ${posts.length} '
                      'posts and clips.',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
                if (top.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const Text(
                    'Top posts',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  for (final p in top.take(5))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      onTap: () => openPostInsights(context, p),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: ClipCover(post: p),
                        ),
                      ),
                      title: Text(
                        p.caption.isEmpty
                            ? (p.isClip ? 'Clip' : 'Post')
                            : p.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        '♥ ${compactCount(p.likesCount)}   💬 ${compactCount(p.commentsCount)}'
                        '   👁 ${compactCount(p.viewsCount)}',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                      trailing: Text(
                        timeAgo(p.createdAt),
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card(this.label, this.value, this.icon);
  final String label;
  final int value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            Icon(icon, color: AppColors.lime, size: 18),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                compactCount(value < 0 ? 0 : value),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
