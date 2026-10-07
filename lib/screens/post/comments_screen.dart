import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/share.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/comment.dart';
import '../../models/post.dart';
import '../../services/giphy.dart';
import '../../services/media_server.dart';
import '../../services/media_service.dart';
import '../../services/post_service.dart';
import '../../services/user_service.dart';
import '../../widgets/comment_tile.dart';
import '../../widgets/reel_actions.dart';
import '../../widgets/state_views.dart';
import '../chat/gif_picker.dart';
import '../profile/profile_screen.dart';
import '../reels/reels_screen.dart';

/// Opens the comments as a sheet that slides up over the current screen (the photo in
/// Discover, the video in Clips). The video keeps playing behind it.
///
/// [onCountChanged] gets +1 when a comment is added and -1 when one is removed.
/// How tall the sheet is. The clips screen uses it to shrink the clip into the space that
/// stays visible above the comments.
double commentsSheetHeight(BuildContext context) {
  final mq = MediaQuery.of(context);
  final keyboard = mq.viewInsets.bottom;
  return math.max(
    260.0,
    math.min(mq.size.height * 0.72, mq.size.height - keyboard - 90),
  );
}

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
      final height = commentsSheetHeight(ctx);
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
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

/// What is attached to the comment that is being written.
class _Attach {
  const _Attach.gif(GifItem this.gif) : photo = null, clip = null;
  const _Attach.photo(File this.photo) : gif = null, clip = null;
  const _Attach.clip(Post this.clip) : gif = null, photo = null;
  final GifItem? gif;
  final File? photo;
  final Post? clip;
}

/// Picks one of your own clips (for "Reply with a clip").
Future<Post?> showClipChooser(BuildContext context) {
  return showModalBottomSheet<Post>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.sizeOf(ctx).height * 0.6,
      child: FutureBuilder<List<Post>>(
        future: PostService.instance.myClips(),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return ErrorState(error: snap.error!, onRetry: () {});
          }
          if (!snap.hasData) return const CenteredLoader();
          final clips = snap.data!;
          if (clips.isEmpty) {
            return EmptyState(
              icon: Icons.smart_display_outlined,
              title: ctx.tr('You have no clips yet'),
              subtitle: ctx.tr('Upload a clip first, then answer with it.'),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 130,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 0.62,
            ),
            itemCount: clips.length,
            itemBuilder: (_, i) {
              final p = clips[i];
              final url = p.isPhotoClip ? p.imageUrl : p.thumbnailUrl;
              return GestureDetector(
                key: ValueKey('chooseClip_${p.id}'),
                onTap: () => Navigator.pop(ctx, p),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: url.isEmpty
                      ? ColoredBox(color: ctx.softFill)
                      : CachedNetworkImage(
                          imageUrl: url,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) =>
                              ColoredBox(color: ctx.softFill),
                        ),
                ),
              );
            },
          );
        },
      ),
    ),
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
  final _focus = FocusNode();
  late final Stream<List<Comment>> _stream = PostService.instance.watchComments(
    widget.post.id,
  );
  bool _sending = false;
  Comment? _replyTo;
  Comment? _editing;
  _Attach? _att;
  final Set<String> _open = {};

  String get _myUid => UserService.instance.myUid;
  int _pinnedNow = 0;

  bool get _iOwnPost => widget.post.authorId == _myUid;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _canSend =>
      !_sending &&
      (_text.text.trim().isNotEmpty || (_att != null && _editing == null));

  Future<void> _send() async {
    if (!_canSend) return;
    final t = _text.text.trim();
    setState(() => _sending = true);
    try {
      final edit = _editing;
      if (edit != null) {
        await PostService.instance.editComment(widget.post.id, edit.id, t);
        if (mounted) setState(() => _editing = null);
      } else {
        final att = _att;
        var imageRef = '';
        if (att?.photo != null) {
          imageRef = (await MediaServer.instance.uploadImage(att!.photo!)).ref;
        }
        final reply = _replyTo;
        final parent = reply == null
            ? ''
            : (reply.isReply ? reply.parentId : reply.id);
        final clip = att?.clip;
        await PostService.instance.addComment(
          widget.post.id,
          t,
          parentId: parent,
          replyToUsername: reply?.authorUsername ?? '',
          gifUrl: att?.gif?.url ?? '',
          gifAspect: att?.gif?.aspect ?? 1,
          imageRef: imageRef,
          clipId: clip?.id ?? '',
          clipThumbRef: clip == null
              ? ''
              : (clip.isPhotoClip ? clip.imageRef : clip.thumbRef),
        );
        widget.onCountChanged?.call(1);
        if (parent.isNotEmpty && mounted) _open.add(parent);
        if (mounted) {
          setState(() {
            _replyTo = null;
            _att = null;
          });
        }
      }
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
      title: context.tr('Delete comment?'),
      confirmLabel: context.tr('Delete'),
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

  void _startReply(Comment c) {
    setState(() {
      _replyTo = c;
      _editing = null;
    });
    _focus.requestFocus();
  }

  Future<void> _pickGif() async {
    if (!GiphyClient().configured) {
      showToast(context, 'GIFs are not set up (missing Giphy key).');
      return;
    }
    final g = await showGifPicker(context);
    if (g != null && mounted) setState(() => _att = _Attach.gif(g));
  }

  Future<void> _pickPhoto() async {
    try {
      final f = await MediaService.pickPostImage(ImageSource.gallery);
      if (f != null && mounted) setState(() => _att = _Attach.photo(f));
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    }
  }

  Future<void> _pickClip() async {
    final p = await showClipChooser(context);
    if (p != null && mounted) setState(() => _att = _Attach.clip(p));
  }

  Future<void> _plus() async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('attachGif'),
              leading: const Icon(Icons.gif_box_outlined),
              title: Text(ctx.tr('GIF')),
              onTap: () => Navigator.pop(ctx, 'gif'),
            ),
            ListTile(
              key: const ValueKey('attachPhoto'),
              leading: const Icon(Icons.photo_outlined),
              title: Text(ctx.tr('Photo')),
              onTap: () => Navigator.pop(ctx, 'photo'),
            ),
            ListTile(
              key: const ValueKey('attachClip'),
              leading: const Icon(Icons.smart_display_outlined),
              title: Text(ctx.tr('One of my clips')),
              onTap: () => Navigator.pop(ctx, 'clip'),
            ),
          ],
        ),
      ),
    );
    switch (pick) {
      case 'gif':
        await _pickGif();
      case 'photo':
        await _pickPhoto();
      case 'clip':
        await _pickClip();
    }
  }

  Future<void> _menu(Comment c) async {
    final mine = c.authorId == _myUid;
    final action = await showCommentMenu(
      context,
      canEdit: mine,
      canDelete: mine || _iOwnPost,
      canReport: !mine,
      canPin: _iOwnPost && !c.isReply,
      pinned: c.pinned,
    );
    if (action == null || !mounted) return;
    switch (action) {
      case CommentAction.reply:
        _startReply(c);
      case CommentAction.replyWithClip:
        _startReply(c);
        await _pickClip();
      case CommentAction.share:
        final link = shareLinkFor(widget.post);
        // ignore: deprecated_member_use
        await Share.share('@${c.authorUsername}: ${c.summary}\n$link');
      case CommentAction.report:
        await showReportSheet(
          context,
          widget.post,
          about: '${c.id} by @${c.authorUsername}: ${c.summary}',
        );
      case CommentAction.edit:
        setState(() {
          _editing = c;
          _replyTo = null;
          _att = null;
          _text.text = c.text;
          _text.selection = TextSelection.collapsed(offset: c.text.length);
        });
        _focus.requestFocus();
      case CommentAction.pin:
        await _pin(c, true);
      case CommentAction.unpin:
        await _pin(c, false);
      case CommentAction.delete:
        await _delete(c);
    }
  }

  Future<void> _pin(Comment c, bool pinned) async {
    if (pinned && _pinnedNow >= kMaxPinnedComments) {
      showToast(
        context,
        'You can pin up to $kMaxPinnedComments comments. Unpin one first.',
      );
      return;
    }
    try {
      await PostService.instance.setCommentPinned(widget.post.id, c.id, pinned);
      if (mounted) showToast(context, pinned ? 'Comment pinned.' : 'Comment unpinned.');
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    }
  }

  Future<void> _openClip(Comment c) async {
    try {
      final p = await PostService.instance.getPost(c.clipId);
      if (!mounted) return;
      if (p == null) {
        showToast(context, 'That clip is not available any more.');
        return;
      }
      openClips(context, p);
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
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              context.tr('Comments'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
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
              _pinnedNow = snap.data!.where((x) => x.pinned).length;
              final threads = buildThreads(snap.data!);
              if (threads.isEmpty) {
                return const EmptyState(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: 'No comments yet',
                  subtitle: 'Be the first to say something.',
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                itemCount: threads.length,
                itemBuilder: (context, i) => _thread(context, threads[i]),
              );
            },
          ),
        ),
        _composer(context),
      ],
    );
  }

  Widget _tile(Comment c) => CommentTile(
    key: ValueKey('c_${c.id}'),
    comment: c,
    postId: widget.post.id,
    onReply: () => _startReply(c),
    onMenu: () => _menu(c),
    onOpenProfile: () => openScreen(context, ProfileScreen(uid: c.authorId)),
    onOpenClip: () => _openClip(c),
  );

  Widget _thread(BuildContext context, CommentThread t) {
    final open = _open.contains(t.root.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _tile(t.root),
        if (t.replies.isNotEmpty && !open)
          Padding(
            padding: const EdgeInsets.only(left: 44, bottom: 14),
            child: GestureDetector(
              key: ValueKey('showReplies_${t.root.id}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _open.add(t.root.id)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 22, height: 1, color: context.muted),
                  const SizedBox(width: 8),
                  Text(
                    '${context.tr('View replies')} (${t.replies.length})',
                    style: TextStyle(
                      color: context.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (open) ...[
          for (final r in t.replies) _tile(r),
          Padding(
            padding: const EdgeInsets.only(left: 44, bottom: 14),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _open.remove(t.root.id)),
              child: Text(
                context.tr('Hide replies'),
                style: TextStyle(
                  color: context.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _chip(BuildContext context, String label, VoidCallback onClose, {Widget? lead}) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: context.softFill,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          if (lead != null) ...[lead, const SizedBox(width: 10)],
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.muted,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('chipClose'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }

  Widget _attachPreview(BuildContext context) {
    final a = _att!;
    Widget lead;
    String label;
    if (a.gif != null) {
      lead = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
          imageUrl: a.gif!.previewUrl,
          width: 44,
          height: 44,
          fit: BoxFit.cover,
        ),
      );
      label = 'GIF';
    } else if (a.photo != null) {
      lead = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(a.photo!, width: 44, height: 44, fit: BoxFit.cover),
      );
      label = context.tr('Photo');
    } else {
      final p = a.clip!;
      final url = p.isPhotoClip ? p.imageUrl : p.thumbnailUrl;
      lead = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: url.isEmpty
            ? const SizedBox(width: 44, height: 44)
            : CachedNetworkImage(
                imageUrl: url,
                width: 44,
                height: 44,
                fit: BoxFit.cover,
              ),
      );
      label = context.tr('Clip');
    }
    return _chip(context, label, () => setState(() => _att = null), lead: lead);
  }

  Widget _composer(BuildContext context) {
    final editing = _editing != null;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_replyTo != null)
            _chip(
              context,
              '${context.tr('Replying to')} @${_replyTo!.authorUsername}',
              () => setState(() => _replyTo = null),
            ),
          if (editing)
            _chip(
              context,
              context.tr('Editing your comment'),
              () => setState(() {
                _editing = null;
                _text.clear();
              }),
            ),
          if (_att != null) _attachPreview(context),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 16, 12),
            child: Row(
              children: [
                if (!editing)
                  IconButton(
                    key: const ValueKey('commentPlus'),
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    onPressed: _plus,
                  )
                else
                  const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    key: const ValueKey('commentField'),
                    controller: _text,
                    focusNode: _focus,
                    minLines: 1,
                    maxLines: 3,
                    maxLength: 300,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: context.tr('Add a comment...'),
                      counterText: '',
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  key: const ValueKey('commentSend'),
                  onTap: _canSend ? _send : null,
                  child: Opacity(
                    opacity: _canSend || _sending ? 1 : 0.45,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: const BoxDecoration(
                        gradient: AppTheme.voltGradient,
                        shape: BoxShape.circle,
                      ),
                      child: _sending
                          ? const Padding(
                              padding: EdgeInsets.all(14),
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: AppTheme.ink,
                              ),
                            )
                          : Icon(
                              editing
                                  ? Icons.check_rounded
                                  : Icons.arrow_upward_rounded,
                              color: AppTheme.ink,
                            ),
                    ),
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
