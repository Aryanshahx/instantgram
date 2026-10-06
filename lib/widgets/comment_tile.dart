import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../core/l10n.dart';
import '../core/theme.dart';
import '../models/comment.dart';
import '../services/post_service.dart';
import 'avatar.dart';
import 'like_button.dart';

/// What the long-press menu of a comment can do.
enum CommentAction { reply, replyWithClip, share, report, edit, delete }

/// The long-press menu: Reply, Reply with a clip, Share and Report for everybody; Edit for
/// the author; Delete for the author and for the owner of the post.
Future<CommentAction?> showCommentMenu(
  BuildContext context, {
  required bool canEdit,
  required bool canDelete,
  required bool canReport,
}) {
  return showModalBottomSheet<CommentAction>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      Widget item(CommentAction a, IconData icon, String label, {bool red = false}) {
        return ListTile(
          key: ValueKey('commentMenu_${a.name}'),
          leading: Icon(icon, color: red ? AppTheme.coral : null),
          title: Text(
            ctx.tr(label),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: red ? AppTheme.coral : null,
            ),
          ),
          onTap: () => Navigator.pop(ctx, a),
        );
      }

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            item(CommentAction.reply, Icons.reply_rounded, 'Reply'),
            item(
              CommentAction.replyWithClip,
              Icons.smart_display_outlined,
              'Reply with a clip',
            ),
            item(CommentAction.share, Icons.ios_share_rounded, 'Share'),
            if (canEdit) item(CommentAction.edit, Icons.edit_outlined, 'Edit'),
            if (canReport)
              item(CommentAction.report, Icons.flag_outlined, 'Report'),
            if (canDelete)
              item(
                CommentAction.delete,
                Icons.delete_outline_rounded,
                'Delete',
                red: true,
              ),
          ],
        ),
      );
    },
  );
}

/// One comment: avatar, name, words, GIF / photo / clip, Reply, and a like on the right.
class CommentTile extends StatelessWidget {
  const CommentTile({
    super.key,
    required this.comment,
    required this.postId,
    required this.onReply,
    required this.onMenu,
    required this.onOpenProfile,
    required this.onOpenClip,
    this.loadLiked,
    this.setLiked,
  });

  final Comment comment;
  final String postId;
  final VoidCallback onReply;
  final VoidCallback onMenu;
  final VoidCallback onOpenProfile;
  final VoidCallback onOpenClip;

  /// Test seams (default: Firestore).
  final Future<bool> Function()? loadLiked;
  final Future<void> Function(bool liked)? setLiked;

  @override
  Widget build(BuildContext context) {
    final c = comment;
    final small = c.isReply;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onMenu,
      child: Padding(
        padding: EdgeInsets.only(left: small ? 44 : 0, bottom: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: onOpenProfile,
              child: UserAvatar(
                url: c.authorPhotoUrl,
                name: c.authorUsername,
                radius: small ? 13 : 17,
                uid: c.authorId,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [
                      Text(
                        c.authorUsername,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        timeago.format(c.createdAt),
                        style: TextStyle(color: context.muted, fontSize: 11.5),
                      ),
                      if (c.edited)
                        Text(
                          context.tr('edited'),
                          key: const ValueKey('editedMark'),
                          style: TextStyle(
                            color: context.muted,
                            fontSize: 11.5,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                    ],
                  ),
                  if (c.text.isNotEmpty || (c.isReply && c.replyToUsername.isNotEmpty))
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text.rich(
                        TextSpan(
                          children: [
                            if (c.isReply && c.replyToUsername.isNotEmpty)
                              TextSpan(
                                text: '@${c.replyToUsername} ',
                                style: TextStyle(
                                  color: context.accentInk,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            TextSpan(text: c.text),
                          ],
                        ),
                        style: const TextStyle(height: 1.3, fontSize: 14.5),
                      ),
                    ),
                  if (c.hasGif) _media(context, c.gifUrl, 190, c.gifAspect),
                  if (c.hasImage) _media(context, c.imageUrl, 210, 0.8),
                  if (c.hasClip) _clip(context),
                  GestureDetector(
                    key: ValueKey('reply_${c.id}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: onReply,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 2),
                      child: Text(
                        context.tr('Reply'),
                        style: TextStyle(
                          color: context.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            CommentLike(
              key: ValueKey('like_${c.id}'),
              postId: postId,
              comment: c,
              loadLiked: loadLiked,
              setLiked: setLiked,
            ),
          ],
        ),
      ),
    );
  }

  Widget _media(BuildContext context, String url, double width, double aspect) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: width,
          child: AspectRatio(
            aspectRatio: aspect.clamp(0.5, 2.2),
            child: CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              placeholder: (_, _) => ColoredBox(color: context.softFill),
              errorWidget: (_, _, _) => ColoredBox(color: context.softFill),
            ),
          ),
        ),
      ),
    );
  }

  Widget _clip(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: GestureDetector(
        key: const ValueKey('commentClip'),
        onTap: onOpenClip,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 110,
            height: 170,
            child: Stack(
              fit: StackFit.expand,
              children: [
                c0(context),
                const Center(
                  child: Icon(
                    Icons.play_circle_fill_rounded,
                    color: Colors.white,
                    size: 38,
                    shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget c0(BuildContext context) => comment.clipThumbUrl.isEmpty
      ? ColoredBox(color: context.softFill)
      : CachedNetworkImage(
          imageUrl: comment.clipThumbUrl,
          fit: BoxFit.cover,
          placeholder: (_, _) => ColoredBox(color: context.softFill),
          errorWidget: (_, _, _) => ColoredBox(color: context.softFill),
        );
}

/// The small heart with its count on the right of a comment.
class CommentLike extends StatefulWidget {
  const CommentLike({
    super.key,
    required this.postId,
    required this.comment,
    this.loadLiked,
    this.setLiked,
  });

  final String postId;
  final Comment comment;
  final Future<bool> Function()? loadLiked;
  final Future<void> Function(bool liked)? setLiked;

  @override
  State<CommentLike> createState() => _CommentLikeState();
}

class _CommentLikeState extends State<CommentLike> {
  bool _liked = false;
  late int _count = widget.comment.likeCount;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CommentLike old) {
    super.didUpdateWidget(old);
    // somebody else's like arrives through the live list
    if (!_busy && old.comment.likeCount != widget.comment.likeCount) {
      _count = widget.comment.likeCount;
    }
  }

  Future<void> _load() async {
    try {
      final v = await (widget.loadLiked ??
          () => PostService.instance.isCommentLiked(
            widget.postId,
            widget.comment.id,
          ))();
      if (mounted) setState(() => _liked = v);
    } catch (_) {}
  }

  Future<void> _tap() async {
    if (_busy) return;
    _busy = true;
    final target = !_liked;
    setState(() {
      _liked = target;
      _count = (_count + (target ? 1 : -1)).clamp(0, 1 << 30);
    });
    try {
      await (widget.setLiked ??
          (v) => PostService.instance.setCommentLike(
            widget.postId,
            widget.comment.id,
            v,
          ))(target);
    } catch (_) {
      if (mounted) {
        setState(() {
          _liked = !target;
          _count = (_count + (target ? -1 : 1)).clamp(0, 1 << 30);
        });
      }
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('commentLike'),
      behavior: HitTestBehavior.opaque,
      onTap: _tap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 2, 0, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: _liked ? 1.15 : 1,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutBack,
              child: Icon(
                _liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                size: 18,
                color: _liked ? kHeartColor : context.muted,
              ),
            ),
            if (_count > 0)
              Text(
                '$_count',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: context.muted,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
