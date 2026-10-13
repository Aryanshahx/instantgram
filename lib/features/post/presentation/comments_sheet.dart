import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/services/gif_search.dart';
import '../../../core/services/media_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/bounce.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/net_image.dart';
import '../../profile/data/user_repository.dart';
import '../data/post_repository.dart';
import 'gif_picker.dart';

/// Most used emojis, shown above the comment box (tap = add).
const kCommentEmojis = ['❤️', '🙌', '🔥', '👏', '😢', '😍', '😮', '😂'];

Future<void> showComments(BuildContext context, Post post) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => CommentsSheet(post: post),
  );
}

/// Picture waiting to be sent with the next comment.
class _Draft {
  _Draft.file(File this.file, {required this.isGif}) : gif = null;
  _Draft.gif(PickedGif g)
    : file = g.file,
      gif = g.gif,
      isGif = true;

  final File? file;
  final GifResult? gif;
  final bool isGif;
}

class CommentsSheet extends StatefulWidget {
  const CommentsSheet({
    super.key,
    required this.post,
    this.stream,
    this.myUid,
  });
  final Post post;

  /// Tests: who is signed in.
  final String? myUid;

  /// Tests pass their own comments.
  final Stream<List<Comment>>? stream;

  @override
  State<CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<CommentsSheet> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  late final Stream<List<Comment>> _stream =
      widget.stream ?? PostRepository.instance.comments(widget.post.id);
  bool _sending = false;
  Comment? _replyTo;
  _Draft? _draft;
  final Set<String> _expanded = {};

  /// Replies shown before "View more replies".
  static const _repliesShown = 2;

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _snack(String t) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  // ---------------------------------------------------------------- input

  void _insert(String s) {
    final v = _ctrl.value;
    final sel = v.selection;
    final start = sel.isValid ? sel.start : v.text.length;
    final end = sel.isValid ? sel.end : v.text.length;
    final text = v.text.replaceRange(start, end, s);
    _ctrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + s.length),
    );
    setState(() {});
  }

  void _reply(Comment c) {
    setState(() => _replyTo = c);
    final tag = '@${c.authorUsername} ';
    if (!_ctrl.text.startsWith(tag)) {
      _ctrl.text = tag + _ctrl.text;
      _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    }
    _focus.requestFocus();
  }

  void _cancelReply() {
    final tag = '@${_replyTo?.authorUsername} ';
    if (_ctrl.text.startsWith(tag)) {
      _ctrl.text = _ctrl.text.substring(tag.length);
    }
    setState(() => _replyTo = null);
  }

  Future<void> _pickPhoto() async {
    try {
      final f = await MediaService.instance.pickGalleryImage(maxWidth: 1440);
      if (f != null && mounted) {
        setState(() => _draft = _Draft.file(f, isGif: false));
      }
    } catch (e) {
      if (mounted) _snack(friendlyError(e));
    }
  }

  Future<void> _pickGif() async {
    final g = await showGifPicker(context);
    if (g != null && mounted) setState(() => _draft = _Draft.gif(g));
  }

  static Future<(int, int)> _size(File f) async {
    try {
      final codec = await ui.instantiateImageCodec(await f.readAsBytes());
      final frame = await codec.getNextFrame();
      final r = (frame.image.width, frame.image.height);
      frame.image.dispose();
      codec.dispose();
      return r;
    } catch (_) {
      return (0, 0);
    }
  }

  Future<void> _send() async {
    var text = _ctrl.text.trim();
    final draft = _draft;
    final reply = _replyTo;
    // "@name " alone is not a comment
    if (reply != null && text == '@${reply.authorUsername}') text = '';
    if ((text.isEmpty && draft == null) || _sending) return;
    setState(() => _sending = true);
    try {
      CommentPicture? pic;
      if (draft != null) {
        final g = draft.gif;
        if (g != null) {
          pic = CommentPicture.gif(
            url: g.url,
            width: g.width,
            height: g.height,
          );
        } else {
          final f = draft.file!;
          final (w, h) = await _size(f);
          final up = await MediaService.instance.upload(
            f,
            kind: MediaKind.comment,
          );
          pic = CommentPicture.image(
            url: up.url,
            key: up.key,
            width: w,
            height: h,
          );
        }
      }
      await PostRepository.instance.addComment(
        widget.post,
        text,
        replyTo: reply,
        picture: pic,
      );
      _ctrl.clear();
      if (mounted) {
        setState(() {
          _draft = null;
          _replyTo = null;
          if (reply != null) {
            _expanded.add(reply.isReply ? reply.parentId : reply.id);
          }
        });
      }
    } catch (e) {
      if (mounted) _snack(friendlyError(e));
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
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: AppColors.like),
            ),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await PostRepository.instance.deleteComment(widget.post.id, c);
      } catch (e) {
        if (mounted) _snack(friendlyError(e));
      }
    }
  }

  // ---------------------------------------------------------------- list

  /// Rows to show: comments, their first replies, "View N more replies".
  List<Object> _rows(List<Comment> all) {
    final out = <Object>[];
    final threaded = threadComments(all);
    var i = 0;
    while (i < threaded.length) {
      final c = threaded[i++];
      out.add(c);
      final replies = <Comment>[];
      while (i < threaded.length && threaded[i].parentId == c.id) {
        replies.add(threaded[i++]);
      }
      final open = _expanded.contains(c.id);
      final shown = open ? replies.length : _repliesShown;
      out.addAll(replies.take(shown));
      if (replies.length > shown) {
        out.add(_MoreReplies(c.id, replies.length - shown));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.myUid ?? UserRepository.instance.myUid;
    final canModerate = widget.post.authorId == me;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
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
                stream: _stream,
                builder: (context, snap) {
                  if (snap.hasError) return ErrorView(error: snap.error);
                  if (!snap.hasData) return const LoadingView();
                  final rows = _rows(snap.data!);
                  if (rows.isEmpty) {
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
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final r = rows[i];
                      if (r is _MoreReplies) {
                        return Padding(
                          padding: const EdgeInsets.only(left: 62, bottom: 6),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              key: ValueKey('more-replies-${r.parentId}'),
                              onPressed: () =>
                                  setState(() => _expanded.add(r.parentId)),
                              child: Text(
                                '—— View ${r.count} more '
                                '${r.count == 1 ? 'reply' : 'replies'}',
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                        );
                      }
                      final c = r as Comment;
                      return CommentTile(
                        key: ValueKey('comment-${c.id}'),
                        postId: widget.post.id,
                        comment: c,
                        canDelete: c.authorId == me || canModerate,
                        onReply: () => _reply(c),
                        onDelete: () => _delete(c),
                      );
                    },
                  );
                },
              ),
            ),
            const Divider(height: 1),
            _composer(),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- composer

  Widget _composer() {
    final draft = _draft;
    final reply = _replyTo;
    final canSend =
        !_sending && (_ctrl.text.trim().isNotEmpty || draft != null);
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (reply != null)
            Container(
              key: const ValueKey('replying-to'),
              color: AppColors.surfaceHigh,
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Replying to @${reply.authorUsername}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Cancel reply',
                    visualDensity: VisualDensity.compact,
                    onPressed: _cancelReply,
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
          // most used emojis
          SizedBox(
            height: 44,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final e in kCommentEmojis)
                  InkResponse(
                    key: ValueKey('emoji-$e'),
                    radius: 22,
                    onTap: () => _insert(e),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(e, style: const TextStyle(fontSize: 23)),
                    ),
                  ),
              ],
            ),
          ),
          if (draft != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
              child: Row(
                children: [
                  _DraftPreview(draft: draft),
                  const SizedBox(width: 8),
                  Text(
                    draft.isGif ? 'GIF' : 'Photo',
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                  const Spacer(),
                  IconButton(
                    key: const ValueKey('draft-remove'),
                    tooltip: 'Remove',
                    onPressed: _sending
                        ? null
                        : () => setState(() => _draft = null),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 6, 8),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('comment-photo'),
                  tooltip: 'Photo',
                  onPressed: _sending ? null : _pickPhoto,
                  icon: const Icon(Icons.image_outlined, size: 24),
                ),
                InkWell(
                  key: const ValueKey('comment-gif'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: _sending ? null : _pickGif,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppColors.textPrimary, width: 1.6),
                    ),
                    child: const Text(
                      'GIF',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const ValueKey('comment-input'),
                    controller: _ctrl,
                    focusNode: _focus,
                    textCapitalization: TextCapitalization.sentences,
                    maxLength: 1000,
                    minLines: 1,
                    maxLines: 4,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      counterText: '',
                      isDense: true,
                      hintText: reply != null
                          ? 'Reply to ${reply.authorUsername}…'
                          : 'Add a comment…',
                      hintStyle: const TextStyle(color: AppColors.textHint),
                      filled: true,
                      fillColor: AppColors.background,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 11,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('comment-send'),
                  onPressed: canSend ? _send : null,
                  icon: _sending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          Icons.send_rounded,
                          color: canSend
                              ? AppColors.lime
                              : AppColors.textSecondary,
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MoreReplies {
  const _MoreReplies(this.parentId, this.count);
  final String parentId;
  final int count;
}

class _DraftPreview extends StatelessWidget {
  const _DraftPreview({required this.draft});
  final _Draft draft;

  @override
  Widget build(BuildContext context) {
    final f = draft.file;
    final g = draft.gif;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 54,
        height: 54,
        child: f != null
            ? Image.file(
                f,
                fit: BoxFit.cover,
                cacheWidth: 160,
                errorBuilder: (c, e, s) =>
                    const ColoredBox(color: AppColors.border),
              )
            : NetImage(g?.preview ?? ''),
      ),
    );
  }
}

/// One comment: avatar, name, time, text / picture, Reply, like heart.
class CommentTile extends StatefulWidget {
  const CommentTile({
    super.key,
    required this.postId,
    required this.comment,
    required this.canDelete,
    required this.onReply,
    required this.onDelete,
    this.likedStream,
  });

  final String postId;
  final Comment comment;
  final bool canDelete;
  final VoidCallback onReply;
  final VoidCallback onDelete;

  /// Tests pass their own "liked" stream.
  final Stream<bool>? likedStream;

  /// Tests: "liked" streams for all tiles.
  @visibleForTesting
  static Stream<bool> Function(String commentId)? debugLiked;

  @override
  State<CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends State<CommentTile> {
  late final Stream<bool> _liked =
      widget.likedStream ??
      CommentTile.debugLiked?.call(widget.comment.id) ??
      PostRepository.instance.isCommentLiked(widget.postId, widget.comment.id);
  bool? _optimistic;

  Future<void> _toggle(bool server) async {
    final now = !(_optimistic ?? server);
    setState(() => _optimistic = now);
    try {
      await PostRepository.instance.setCommentLiked(
        widget.postId,
        widget.comment.id,
        now,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _optimistic = null);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.comment;
    final reply = c.isReply;
    final pic = c.pictureUrl;
    return StreamBuilder<bool>(
      stream: _liked,
      builder: (context, snap) {
        final server = snap.data ?? false;
        if (_optimistic == server) _optimistic = null;
        final liked = _optimistic ?? server;
        var count = c.likesCount;
        if (_optimistic != null && _optimistic != server) {
          count += _optimistic! ? 1 : -1;
        }
        if (count < 0) count = 0;
        return InkWell(
          onLongPress: widget.canDelete ? widget.onDelete : null,
          child: Padding(
            padding: EdgeInsets.fromLTRB(reply ? 62 : 14, 8, 4, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () => openProfile(context, c.authorId),
                  child: Avatar(
                    url: c.authorPhotoUrl,
                    name: c.authorUsername,
                    size: reply ? 28 : 36,
                    uid: c.authorId,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '${c.authorUsername}  ',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                            TextSpan(
                              text: timeAgo(c.createdAt),
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (c.text.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: _CommentText(text: c.text),
                        ),
                      if (pic.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: 200,
                              maxHeight: 240,
                            ),
                            child: AspectRatio(
                              aspectRatio: c.pictureAspect,
                              child: ClipRRect(
                                key: ValueKey('comment-pic-${c.id}'),
                                borderRadius: BorderRadius.circular(10),
                                child: NetImage(pic),
                              ),
                            ),
                          ),
                        ),
                      Row(
                        children: [
                          TextButton(
                            key: ValueKey('reply-${c.id}'),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 0,
                              ),
                              minimumSize: const Size(44, 30),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              foregroundColor: AppColors.textSecondary,
                            ),
                            onPressed: widget.onReply,
                            child: const Text(
                              'Reply',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (widget.canDelete) ...[
                            const SizedBox(width: 10),
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 0,
                                ),
                                minimumSize: const Size(44, 30),
                                tapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                foregroundColor: AppColors.textSecondary,
                              ),
                              onPressed: widget.onDelete,
                              child: const Text(
                                'Delete',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Column(
                    children: [
                      IconButton(
                        key: ValueKey('comment-like-${c.id}'),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _toggle(server),
                        icon: Bounce(
                          trigger: liked,
                          big: liked,
                          child: Icon(
                            liked ? Icons.favorite : Icons.favorite_border,
                            size: 17,
                            color: liked
                                ? AppColors.like
                                : AppColors.textSecondary,
                          ),
                        ),
                      ),
                      if (count > 0)
                        Text(
                          '$count',
                          key: ValueKey('comment-likes-${c.id}'),
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Comment text; a leading "@name" is shown in lime.
class _CommentText extends StatelessWidget {
  const _CommentText({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    const base = TextStyle(color: AppColors.textPrimary, fontSize: 14.5);
    final m = RegExp(r'^@[a-z0-9._]+').firstMatch(text);
    if (m == null) return Text(text, style: base);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(
            text: m.group(0),
            style: const TextStyle(
              color: AppColors.lime,
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(text: text.substring(m.end)),
        ],
      ),
    );
  }
}
