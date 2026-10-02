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
  late final Stream<List<Comment>> _stream =
      PostService.instance.watchComments(widget.post.id);
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
      appBar: AppBar(
        title:
            const Text('Comments', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: Column(
        children: [
          if (post.caption.isNotEmpty) ...[
            ListTile(
              leading: UserAvatar(url: post.authorPhotoUrl, radius: 18),
              title: Text.rich(TextSpan(children: [
                TextSpan(
                  text: '${post.authorUsername} ',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                TextSpan(text: post.caption),
              ])),
              subtitle: Text(timeago.format(post.createdAt)),
            ),
            const Divider(),
          ],
          Expanded(
            child: StreamBuilder<List<Comment>>(
              stream: _stream,
              builder: (context, snap) {
                if (snap.hasError) {
                  return ErrorState(
                      error: snap.error!, onRetry: () => setState(() {}));
                }
                if (!snap.hasData) return const CenteredLoader();
                final comments = snap.data!;
                if (comments.isEmpty) {
                  return const EmptyState(
                    icon: Icons.mode_comment_outlined,
                    title: 'No comments yet',
                    subtitle: 'Start the conversation.',
                  );
                }
                return ListView.builder(
                  itemCount: comments.length,
                  itemBuilder: (context, i) {
                    final c = comments[i];
                    final mine = c.authorId == _myUid;
                    return ListTile(
                      leading: GestureDetector(
                        onTap: () =>
                            openScreen(context, ProfileScreen(uid: c.authorId)),
                        child: UserAvatar(url: c.authorPhotoUrl, radius: 18),
                      ),
                      title: Text.rich(TextSpan(children: [
                        TextSpan(
                          text: '${c.authorUsername} ',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(text: c.text),
                      ])),
                      subtitle: Text(timeago.format(c.createdAt),
                          style: TextStyle(color: context.muted, fontSize: 12)),
                      trailing: mine
                          ? IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () => _delete(c),
                            )
                          : null,
                    );
                  },
                );
              },
            ),
          ),
          const Divider(),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
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
                  TextButton(
                    onPressed: _sending ? null : _send,
                    child: const Text('Post',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
