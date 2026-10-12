import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/net_image.dart';
import '../../../shared/widgets/post_grid.dart';
import '../../post/data/post_repository.dart';
import '../../profile/data/user_repository.dart';

/// Real stats for your account, added up from your posts.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<(UserProfile, List<Post>)> _future = _load();

  Future<(UserProfile, List<Post>)> _load() async {
    final me = await UserRepository.instance.me();
    final posts = await PostRepository.instance.allByUser(me.uid);
    return (me, posts);
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
        child: FutureBuilder<(UserProfile, List<Post>)>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) {
              return ListView(children: [ErrorView(error: snap.error)]);
            }
            if (!snap.hasData) return const LoadingView();
            final (me, posts) = snap.data!;
            int sum(int Function(Post p) f) =>
                posts.fold(0, (a, p) => a + f(p));
            final likes = sum((p) => p.likesCount);
            final comments = sum((p) => p.commentsCount);
            final reposts = sum((p) => p.repostsCount);
            final views =
                posts.where((p) => p.isClip).fold(0, (a, p) => a + p.viewsCount);
            final clips = posts.where((p) => p.isClip).length;
            final top = [...posts]
              ..sort((a, b) => (b.likesCount + b.commentsCount)
                  .compareTo(a.likesCount + a.commentsCount));
            final avg = posts.isEmpty ? 0 : (likes / posts.length).round();

            return ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
              children: [
                const Text(
                  'Overview',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.7,
                  children: [
                    _Card('Followers', me.followersCount, Icons.people),
                    _Card('Following', me.followingCount, Icons.person_add_alt),
                    _Card('Posts', posts.length - clips, Icons.grid_view_rounded),
                    _Card('Clips', clips, Icons.smart_display),
                    _Card('Total likes', likes, Icons.favorite),
                    _Card('Comments', comments, Icons.chat_bubble),
                    _Card('Reposts', reposts, Icons.repeat),
                    _Card('Clip views', views, Icons.play_arrow_rounded),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: AppColors.fabGradient,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.trending_up, color: Colors.black, size: 30),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          posts.isEmpty
                              ? 'Share your first post to see insights.'
                              : 'Average $avg likes per post',
                          style: const TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (top.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  const Text(
                    'Top posts',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  for (final p in top.take(5))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      onTap: () => openPost(context, [p], 0),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(
                          width: 54,
                          height: 54,
                          child: p.isClip
                              ? ClipCover(post: p)
                              : NetImage(p.mediaUrl),
                        ),
                      ),
                      title: Text(
                        p.caption.isEmpty
                            ? (p.isClip ? 'Clip' : 'Photo')
                            : p.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        '♥ ${compactCount(p.likesCount)}   💬 ${compactCount(p.commentsCount)}'
                        '${p.isClip ? '   ▶ ${compactCount(p.viewsCount)}' : ''}',
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
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, color: AppColors.lime, size: 22),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                compactCount(value < 0 ? 0 : value),
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
