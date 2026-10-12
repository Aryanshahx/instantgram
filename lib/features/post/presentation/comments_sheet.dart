import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../profile/data/user_repository.dart';
import '../data/post_repository.dart';

Future<void> showComments(BuildContext context, Post post) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => CommentsSheet(post: post),
  );
}

class CommentsSheet extends StatefulWidget {
  const CommentsSheet({super.key, required this.post});
  final Post post;

  @override
  State<CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<CommentsSheet> {
  final _ctrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await PostRepository.instance.addComment(widget.post, text);
      _ctrl.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _delete(Comment c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete comment?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete',
                  style: TextStyle(color: AppColors.like))),
        ],
      ),
    );
    if (ok == true) {
      await PostRepository.instance.deleteComment(widget.post.id, c.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = UserRepository.instance.myUid;
    final canModerate = widget.post.authorId == me;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          children: [
            const Text(
              'Comments',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            Expanded(
              child: StreamBuilder<List<Comment>>(
                stream: PostRepository.instance.comments(widget.post.id),
                builder: (context, snap) {
                  if (snap.hasError) return ErrorView(error: snap.error);
                  if (!snap.hasData) return const LoadingView();
                  final list = snap.data!;
                  if (list.isEmpty) {
                    return const Center(
                      child: EmptyState(
                        icon: Icons.chat_bubble_outline,
                        title: 'No comments yet',
                        subtitle: 'Start the conversation.',
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final c = list[i];
                      final canDelete = c.authorId == me || canModerate;
                      return ListTile(
                        onLongPress: canDelete ? () => _delete(c) : null,
                        leading: GestureDetector(
                          onTap: () => openProfile(context, c.authorId),
                          child: Avatar(
                            url: c.authorPhotoUrl,
                            name: c.authorUsername,
                            size: 38,
                          ),
                        ),
                        title: Text.rich(
                          TextSpan(children: [
                            TextSpan(
                              text: '${c.authorUsername}  ',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            TextSpan(
                              text: timeAgo(c.createdAt),
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ]),
                        ),
                        subtitle: Text(
                          c.text,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15,
                          ),
                        ),
                        trailing: canDelete
                            ? IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 20, color: AppColors.textSecondary),
                                onPressed: () => _delete(c),
                              )
                            : null,
                      );
                    },
                  );
                },
              ),
            ),
            const Divider(height: 1),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ctrl,
                        textCapitalization: TextCapitalization.sentences,
                        maxLength: 1000,
                        onSubmitted: (_) => _send(),
                        decoration: InputDecoration(
                          counterText: '',
                          hintText: 'Add a comment…',
                          hintStyle:
                              const TextStyle(color: AppColors.textHint),
                          filled: true,
                          fillColor: AppColors.background,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide:
                                const BorderSide(color: AppColors.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide:
                                const BorderSide(color: AppColors.border),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _sending ? null : _send,
                      icon: _sending
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.send_rounded,
                              color: AppColors.lime),
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
