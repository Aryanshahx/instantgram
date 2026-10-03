import 'package:flutter/material.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/responsive.dart';
import '../../core/ui.dart';
import '../../models/comment.dart';
import '../../models/post.dart';
import '../../services/post_service.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/state_views.dart';
import '../profile/profile_screen.dart';

class CommentsScreen extends StatefulWidget {
  const CommentsScreen({super.key, required this.post, this.onCountChanged});

  final Post post;

  /// +1 when a comment is added, -1 when removed.
  final void Function(int delta)? onCountChanged;

  @override
  State<CommentsScreen> createState() => _CommentsScreenState();
}

class _CommentsScreenState extends State<CommentsScreen> {
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
    final post = widget.post;
    return Scaffold(
      appBar: AppBar(title: const Text('Comments')),
      body: ContentWidth(
        maxWidth: 680,
        child: Column(
          children: [
            if (post.caption.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: context.card,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: context.hairline.withValues(alpha: 0.7),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    UserAvatar(
                      url: post.authorPhotoUrl,
                      name: post.authorUsername,
                      radius: 18,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '@${post.authorUsername}',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            post.caption,
                            style: const TextStyle(height: 1.35),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
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
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    itemCount: comments.length,
                    itemBuilder: (context, i) {
                      final c = comments[i];
                      final mine = c.authorId == _myUid;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              onTap: () => openScreen(
                                context,
                                ProfileScreen(uid: c.authorId),
                              ),
                              child: UserAvatar(
                                url: c.authorPhotoUrl,
                                name: c.authorUsername,
                                radius: 18,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  10,
                                  8,
                                  10,
                                ),
                                decoration: BoxDecoration(
                                  color: mine
                                      ? AppTheme.volt.withValues(
                                          alpha: context.isDark ? 0.14 : 0.45,
                                        )
                                      : context.card,
                                  borderRadius: const BorderRadius.only(
                                    topLeft: Radius.circular(6),
                                    topRight: Radius.circular(22),
                                    bottomLeft: Radius.circular(22),
                                    bottomRight: Radius.circular(22),
                                  ),
                                  border: Border.all(
                                    color: context.hairline.withValues(
                                      alpha: 0.6,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
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
                                                style: TextStyle(
                                                  color: context.muted,
                                                  fontSize: 11.5,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            c.text,
                                            style: const TextStyle(height: 1.3),
                                          ),
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
                                            size: 19,
                                            color: context.muted,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
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
                          hintText: 'Write a comment...',
                          counterText: '',
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: _sending ? null : _send,
                      child: Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          gradient: AppTheme.voltGradient,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: _sending
                            ? const Padding(
                                padding: EdgeInsets.all(16),
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
        ),
      ),
    );
  }
}
