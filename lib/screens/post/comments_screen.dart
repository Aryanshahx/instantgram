import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/comment.dart';
import '../../models/post.dart';
import '../../services/post_service.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/state_views.dart';
import '../profile/profile_screen.dart';

/// Opens the comments as a sheet that slides up over the current screen (the photo in
/// Discover, the video in Clips). The video keeps playing behind it.
///
/// [onCountChanged] gets +1 when a comment is added and -1 when one is removed.
Future<void> showCommentsSheet(
  BuildContext context, {
  required Post post,
  void Function(int delta)? onCountChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (ctx) {
      final mq = MediaQuery.of(ctx);
      final keyboard = mq.viewInsets.bottom;
      final height = math.max(
        260.0,
        math.min(mq.size.height * 0.72, mq.size.height - keyboard - 90),
      );
      return Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: Theme.of(ctx).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: CommentsPanel(post: post, onCountChanged: onCountChanged),
        ),
      );
    },
  );
}

/// The comment list and the input box.
class CommentsPanel extends StatefulWidget {
  const CommentsPanel({super.key, required this.post, this.onCountChanged});

  final Post post;
  final void Function(int delta)? onCountChanged;

  @override
  State<CommentsPanel> createState() => _CommentsPanelState();
}

class _CommentsPanelState extends State<CommentsPanel> {
  final _text = TextEditingController();
  late final Stream<List<Comment>> _stream = PostService.instance.watchComments(
    widget.post.id,
  );
  bool _sending = false;

  String get _myUid => UserService.instance.myUid;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await PostService.instance.addComment(widget.post.id, t);
      widget.onCountChanged?.call(1);
      _text.clear();
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _delete(Comment c) async {
    final ok = await confirm(
      context,
      title: 'Delete comment?',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    try {
      await PostService.instance.deleteComment(widget.post.id, c.id);
      widget.onCountChanged?.call(-1);
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 10),
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: context.hairline,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Comments',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
          ),
        ),
        Divider(height: 1, color: context.hairline.withValues(alpha: 0.7)),
        Expanded(
          child: StreamBuilder<List<Comment>>(
            stream: _stream,
            builder: (context, snap) {
              if (snap.hasError) {
                return ErrorState(
                  error: snap.error!,
                  onRetry: () => setState(() {}),
                );
              }
              if (!snap.hasData) return const CenteredLoader();
              final comments = snap.data!;
              if (comments.isEmpty) {
                return const EmptyState(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: 'No comments yet',
                  subtitle: 'Be the first to say something.',
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                itemCount: comments.length,
                itemBuilder: (context, i) => _row(context, comments[i]),
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 3,
                    maxLength: 300,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Add a comment...',
                      counterText: '',
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: _sending ? null : _send,
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      gradient: AppTheme.voltGradient,
                      shape: BoxShape.circle,
                    ),
                    child: _sending
                        ? const Padding(
                            padding: EdgeInsets.all(15),
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: AppTheme.ink,
                            ),
                          )
                        : const Icon(
                            Icons.arrow_upward_rounded,
                            color: AppTheme.ink,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, Comment c) {
    final mine = c.authorId == _myUid;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => openScreen(context, ProfileScreen(uid: c.authorId)),
            child: UserAvatar(
              url: c.authorPhotoUrl,
              name: c.authorUsername,
              radius: 18,
              uid: c.authorId,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      c.authorUsername,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13.5,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      timeago.format(c.createdAt),
                      style: TextStyle(color: context.muted, fontSize: 11.5),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(c.text, style: const TextStyle(height: 1.3)),
              ],
            ),
          ),
          if (mine)
            GestureDetector(
              onTap: () => _delete(c),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.delete_outline_rounded,
                  size: 20,
                  color: context.muted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
