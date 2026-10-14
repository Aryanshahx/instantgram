import 'package:flutter/material.dart';

import '../../../core/services/content_filter.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/net_image.dart';
import '../../post/presentation/post_detail_screen.dart';
import '../../profile/data/user_repository.dart';
import '../../settings/presentation/privacy_screens.dart';
import '../data/notification_repository.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final _repo = NotificationRepository.instance;
  late final Stream<List<AppNotification>> _stream = _repo.watchMine();
  late final Stream<List<dynamic>> _requests = UserRepository.instance
      .followRequests();

  Widget _requestsTile() => StreamBuilder<List<dynamic>>(
    stream: _requests,
    builder: (context, s) {
      final n = s.data?.length ?? 0;
      if (n == 0) return const SizedBox.shrink();
      return ListTile(
        key: const ValueKey('follow-requests'),
        leading: Container(
          width: 46,
          height: 46,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: AppColors.fabGradient,
          ),
          child: const Icon(Icons.person_add_alt_1, color: Colors.black),
        ),
        title: const Text(
          'Follow requests',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '$n waiting for you',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const FollowRequestsScreen()),
        ),
      );
    },
  );

  @override
  void dispose() {
    _repo.markAllRead();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton(
            onPressed: _repo.markAllRead,
            child: const Text(
              'Mark all read',
              style: TextStyle(color: AppColors.lime),
            ),
          ),
        ],
      ),
      body: StreamBuilder<List<AppNotification>>(
        stream: _stream,
        builder: (context, snap) {
          if (snap.hasError) return ErrorView(error: snap.error);
          if (!snap.hasData) return const LoadingView();
          final list = snap.data!
              .where((n) => !ContentFilter.instance.isBlocked(n.fromUid))
              .toList();
          if (list.isEmpty) {
            return ListView(
              children: [
                _requestsTile(),
                const EmptyState(
                  icon: Icons.notifications_none,
                  title: 'No notifications yet',
                  subtitle: 'Likes, comments and new followers show up here.',
                ),
              ],
            );
          }
          return ListView.builder(
            itemCount: list.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) return _requestsTile();
              final n = list[index - 1];
              return Container(
                color: n.read
                    ? Colors.transparent
                    : AppColors.lime.withValues(alpha: 0.06),
                child: ListTile(
                  onTap: () {
                    if (n.type == AppNotification.notice) {
                      _showNotice(context, n);
                    } else if (n.postId.isNotEmpty) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PostDetailScreen(postId: n.postId),
                        ),
                      );
                    } else {
                      openProfile(context, n.fromUid);
                    }
                  },
                  leading: n.type == AppNotification.notice
                      ? const _NoticeBadge()
                      : n.type == AppNotification.views
                      ? const _ViewsBadge()
                      : GestureDetector(
                          onTap: () => openProfile(context, n.fromUid),
                          child: Avatar(
                            url: n.fromPhotoUrl,
                            name: n.fromUsername,
                            size: 46,
                            uid: n.fromUid,
                          ),
                        ),
                  title: Text.rich(
                    TextSpan(
                      children: [
                        if (n.fromUsername.isNotEmpty)
                          TextSpan(
                            text: '${n.fromUsername} ',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        TextSpan(text: notificationText(n)),
                        TextSpan(
                          text: '  ${timeAgo(n.createdAt)}',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
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
                      : _typeIcon(n.type),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// v0.13: a message from the InstantGram team (admin website).
void _showNotice(BuildContext context, AppNotification n) {
  showDialog<void>(
    context: context,
    builder: (d) => AlertDialog(
      icon: const _NoticeBadge(),
      title: const Text('InstantGram'),
      content: SingleChildScrollView(child: SelectableText(n.text)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

class _NoticeBadge extends StatelessWidget {
  const _NoticeBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('notice-badge'),
      width: 46,
      height: 46,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [AppColors.lime, Color(0xFF7CFFB2)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Icon(Icons.campaign_rounded, color: Colors.black, size: 24),
    );
  }
}

Widget? _typeIcon(String type) => switch (type) {
  AppNotification.follow => const Icon(
    Icons.person_add_alt_1,
    color: AppColors.lime,
  ),
  AppNotification.unfollow => const Icon(
    Icons.person_remove_alt_1_outlined,
    color: AppColors.textSecondary,
  ),
  AppNotification.commentLike => const Icon(
    Icons.favorite,
    color: AppColors.like,
    size: 20,
  ),
  _ => null,
};

/// Text after the username (v0.12: + reply, comment like, unfollow, views).
String notificationText(AppNotification n) {
  switch (n.type) {
    case AppNotification.like:
      return 'liked your post.';
    case AppNotification.comment:
      return 'commented: ${n.text}';
    case AppNotification.reply:
      return 'replied to your comment: ${n.text}';
    case AppNotification.commentLike:
      return n.text.isEmpty
          ? 'liked your comment.'
          : 'liked your comment: ${n.text}';
    case AppNotification.follow:
      return 'started following you.';
    case AppNotification.unfollow:
      return 'unfollowed you.';
    case AppNotification.repost:
      return 'reposted your post.';
    case AppNotification.views:
      final v = int.tryParse(n.text) ?? 0;
      return '🎉 Your post reached ${compactViews(v)} views!';
    default:
      return n.text;
  }
}

/// 1000 -> 1K, 1500000 -> 1.5M.
String compactViews(int v) {
  String f(double x, String u) {
    final s = x.toStringAsFixed(x >= 10 || x == x.roundToDouble() ? 0 : 1);
    return '$s$u';
  }

  if (v >= 1000000) return f(v / 1000000, 'M');
  if (v >= 1000) return f(v / 1000, 'K');
  return '$v';
}

class _ViewsBadge extends StatelessWidget {
  const _ViewsBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.lime.withValues(alpha: 0.15),
      ),
      child: const Icon(Icons.bar_chart_rounded, color: AppColors.lime),
    );
  }
}
