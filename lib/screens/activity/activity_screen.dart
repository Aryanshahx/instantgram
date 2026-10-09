import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../../core/media_url.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/app_notification.dart';
import '../../models/post.dart';
import '../../services/notification_service.dart';
import '../../services/post_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/state_views.dart';
import '../profile/profile_screen.dart';
import '../reels/reels_screen.dart';
import '../../widgets/post_details_sheet.dart';

/// What the bell in Discover opens: likes, comments, replies and follows.
///
/// There are no push notifications, so this is the activity while the app is open. Opening
/// it marks everything as seen.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  @override
  void initState() {
    super.initState();
    NotificationService.instance.markAllRead();
  }

  Future<void> _open(AppNotification n) async {
    if (n.isFromTeam) {
      await showTeamMessage(context, n);
      return;
    }
    if (n.isFollow || n.postId.isEmpty) {
      if (n.actorId.isNotEmpty) {
        openScreen(context, ProfileScreen(uid: n.actorId));
      }
      return;
    }
    Post? post;
    try {
      post = await PostService.instance.getPost(n.postId);
    } catch (_) {
      post = null;
    }
    if (!mounted) return;
    if (post == null) {
      showToast(context, 'That post is not available any more.');
      return;
    }
    if (post.isClip) {
      openClips(context, post);
    } else {
      showPostDetails(context, post);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: StreamBuilder<List<AppNotification>>(
        stream: NotificationService.instance.watch(),
        builder: (context, snap) {
          if (snap.hasError) {
            return ErrorState(
              error: snap.error!,
              onRetry: () => setState(() {}),
            );
          }
          if (!snap.hasData) return const CenteredLoader();
          final items = snap.data!;
          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.notifications_none_rounded,
              title: 'Nothing yet',
              subtitle:
                  'Likes, comments and new followers show up here as they happen.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: items.length,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              color: context.hairline.withValues(alpha: 0.6),
            ),
            itemBuilder: (context, i) =>
                _Row(n: items[i], onTap: () => _open(items[i])),
          );
        },
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.n, required this.onTap});

  final AppNotification n;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final thumb = resolveMediaUrl(n.thumb);
    return ListTile(
      key: ValueKey('activity_${n.id}'),
      contentPadding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      onTap: onTap,
      leading: n.isFromTeam
          ? CircleAvatar(
              radius: 22,
              backgroundColor: n.type == 'warning'
                  ? AppTheme.coral
                  : AppTheme.volt,
              child: Icon(
                n.type == 'warning'
                    ? Icons.warning_amber_rounded
                    : Icons.campaign_rounded,
                color: AppTheme.ink,
              ),
            )
          : UserAvatar(url: n.actorPhoto, name: n.actorName, radius: 22),
      title: RichText(
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 14.5,
            height: 1.3,
          ),
          children: [
            TextSpan(
              text: n.isFromTeam
                  ? 'InstantGram'
                  : (n.actorName.isEmpty ? 'Someone' : n.actorName),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            if (n.type == 'warning')
              const TextSpan(
                text: '  \u26a0\ufe0f Warning',
                style: TextStyle(
                  color: AppTheme.coral,
                  fontWeight: FontWeight.w800,
                ),
              )
            else if (n.verb.isNotEmpty)
              TextSpan(
                text: ' ${n.verb}',
                style: n.isFromTeam
                    ? const TextStyle(fontWeight: FontWeight.w700)
                    : null,
              ),
            if (n.text.isNotEmpty) TextSpan(text: '  ${n.text}'),
          ],
        ),
      ),
      subtitle: n.createdAt == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                timeago.format(n.createdAt!),
                style: TextStyle(color: context.muted, fontSize: 12),
              ),
            ),
      trailing: n.isFollow || thumb.isEmpty
          ? (n.read
                ? null
                : const Icon(Icons.circle, size: 9, color: AppTheme.coral))
          : ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: thumb,
                width: 46,
                height: 46,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => const SizedBox(width: 46, height: 46),
              ),
            ),
    );
  }
}

/// A message or warning from the InstantGram team, in full (with its picture).
Future<void> showTeamMessage(BuildContext context, AppNotification n) {
  final img = resolveMediaUrl(n.thumb);
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('teamMessage'),
      title: Text(
        n.type == 'warning'
            ? 'Warning from InstantGram'
            : (n.title.isEmpty ? 'InstantGram' : n.title),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (img.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CachedNetworkImage(
                    imageUrl: img,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            Text(n.text),
            if (n.type == 'warning') ...[
              const SizedBox(height: 12),
              Text(
                'More warnings can lead to a suspension. Write to techlabs.hyper@gmail.com if you think this is a mistake.',
                style: TextStyle(color: ctx.muted, fontSize: 12.5),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
