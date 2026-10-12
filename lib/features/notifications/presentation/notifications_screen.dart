import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/net_image.dart';
import '../../post/presentation/post_detail_screen.dart';
import '../data/notification_repository.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final _repo = NotificationRepository.instance;
  late final Stream<List<AppNotification>> _stream = _repo.watchMine();

  @override
  void dispose() {
    _repo.markAllRead();
    super.dispose();
  }

  String _text(AppNotification n) {
    switch (n.type) {
      case AppNotification.like:
        return 'liked your post.';
      case AppNotification.comment:
        return 'commented: ${n.text}';
      case AppNotification.follow:
        return 'started following you.';
      case AppNotification.repost:
        return 'reposted your post.';
      default:
        return n.text;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton(
            onPressed: _repo.markAllRead,
            child: const Text('Mark all read',
                style: TextStyle(color: AppColors.lime)),
          ),
        ],
      ),
      body: StreamBuilder<List<AppNotification>>(
        stream: _stream,
        builder: (context, snap) {
          if (snap.hasError) return ErrorView(error: snap.error);
          if (!snap.hasData) return const LoadingView();
          final list = snap.data!;
          if (list.isEmpty) {
            return const Center(
              child: EmptyState(
                icon: Icons.notifications_none,
                title: 'No notifications yet',
                subtitle: 'Likes, comments and new followers show up here.',
              ),
            );
          }
          return ListView.builder(
            itemCount: list.length,
            itemBuilder: (context, i) {
              final n = list[i];
              return Container(
                color: n.read
                    ? Colors.transparent
                    : AppColors.lime.withValues(alpha: 0.06),
                child: ListTile(
                  onTap: () {
                    if (n.postId.isNotEmpty) {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => PostDetailScreen(postId: n.postId),
                      ));
                    } else {
                      openProfile(context, n.fromUid);
                    }
                  },
                  leading: GestureDetector(
                    onTap: () => openProfile(context, n.fromUid),
                    child: Avatar(
                        url: n.fromPhotoUrl, name: n.fromUsername, size: 46),
                  ),
                  title: Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: '${n.fromUsername} ',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(text: _text(n)),
                      TextSpan(
                        text: '  ${timeAgo(n.createdAt)}',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    ]),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: n.postThumb.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 46,
                            height: 46,
                            child: NetImage(n.postThumb),
                          ),
                        )
                      : (n.type == AppNotification.follow
                          ? const Icon(Icons.person_add_alt_1,
                              color: AppColors.lime)
                          : null),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
