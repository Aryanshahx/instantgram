import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/services/gif_search.dart';
import '../../../core/services/hyper_intelligence.dart';
import '../../../core/services/media_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/email.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/attach_menu.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/bounce.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/net_image.dart';
import '../../profile/data/user_repository.dart';
import '../data/post_repository.dart';
import '../data/report_repository.dart';
import 'create_sheet.dart';
import 'gif_picker.dart';
import 'my_post_picker.dart';
import '../../../shared/widgets/tagged_text.dart';
import '../../../shared/widgets/verified_badge.dart';
import '../../../shared/widgets/hi_text_check.dart';

/// v0.11: text for "Share" on a comment.
String commentShareText(Post post, Comment c) {
  final what = post.isClip ? 'clip' : 'post';
  final text = c.text.isNotEmpty ? '"${c.text}"' : '(photo / GIF comment)';
  final link = post.coverUrl.isNotEmpty ? post.coverUrl : post.mediaUrl;
  return '$text\n— @${c.authorUsername}, on a $what by '
      '@${post.authorUsername} on InstantGram\n$link';
}

/// Most used emojis, shown above the comment box (tap = add).
const kCommentEmojis = ['❤️', '🙌', '🔥', '👏', '😢', '😍', '😮', '😂'];

/// Comments panel (v0.9): opens at 60 % of the screen, drag it up to full
/// screen or down to close.
///
/// [onSheetTop] gets where the panel's top edge is (pixels from the top of
/// the screen; null = closed). Clips use it to show the video small above
/// the panel and to pause it when the panel is full screen. With
/// [onSheetTop] the area above the panel is not darkened.
Future<void> showComments(
  BuildContext context,
  Post post, {
  ValueChanged<double?>? onSheetTop,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: false,
    showDragHandle: false,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: onSheetTop != null ? Colors.transparent : null,
    builder: (_) => CommentsPanel(post: post, onSheetTop: onSheetTop),
  );
  // v0.10: no null here. The future ends when the close STARTS; the panel
  // itself says null when the close animation is really finished (before,
  // its last slide reports came after the null and the clip stayed small
  // with no buttons).
}

/// Draggable comments panel: 60 % -> full screen, or down to close.
class CommentsPanel extends StatefulWidget {
  const CommentsPanel({
    super.key,
    required this.post,
    this.onSheetTop,
    this.stream,
    this.myUid,
  });

  final Post post;
  final ValueChanged<double?>? onSheetTop;

  /// Tests.
  final Stream<List<Comment>>? stream;
  final String? myUid;

  static const double half = 0.6;
  static const double min = 0.25;

  @override
  State<CommentsPanel> createState() => _CommentsPanelState();
}

class _CommentsPanelState extends State<CommentsPanel> {
  final _dsc = DraggableScrollableController();
  final _topInset = ValueNotifier<double>(0);
  double _extent = CommentsPanel.half;
  double _avail = 0;
  bool _full = false;
  Animation<double>? _routeAnim;

  /// v0.10: the panel is gone (close animation done). Nothing is reported
  /// after this, so the clip can't get stuck in small mode.
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // follow the open / close slide, so the video grows back smoothly
    final a = ModalRoute.of(context)?.animation;
    if (a != _routeAnim) {
      _routeAnim?.removeListener(_report);
      _routeAnim?.removeStatusListener(_onRouteStatus);
      _routeAnim = a;
      a?.addListener(_report);
      a?.addStatusListener(_onRouteStatus);
    }
  }

  @override
  void dispose() {
    _routeAnim?.removeListener(_report);
    _routeAnim?.removeStatusListener(_onRouteStatus);
    if (!_closed) {
      // safety: closed without the animation (route removed at once)
      _closed = true;
      final cb = widget.onSheetTop;
      if (cb != null) scheduleMicrotask(() => cb(null));
    }
    _dsc.dispose();
    _topInset.dispose();
    super.dispose();
  }

  void _onRouteStatus(AnimationStatus s) {
    if (s == AnimationStatus.dismissed) _sayClosed();
  }

  void _sayClosed() {
    if (_closed) return;
    _closed = true;
    widget.onSheetTop?.call(null);
  }

  void _report() {
    if (_closed || !mounted) return;
    if (_routeAnim?.status == AnimationStatus.dismissed) {
      _sayClosed();
      return;
    }
    if (_avail <= 0) return;
    final top = _avail * (1 - _extent);
    final a = Easing.legacyDecelerate.transform(
      (_routeAnim?.value ?? 1).clamp(0.0, 1.0),
    );
    widget.onSheetTop?.call(_avail - (_avail - top) * a);
    final pad = MediaQuery.paddingOf(context).top;
    _topInset.value = (pad - top).clamp(0.0, pad);
    final full = top < 1;
    if (full != _full) setState(() => _full = full);
  }

  bool _onExtent(DraggableScrollableNotification n) {
    _extent = n.extent;
    _report();
    return false;
  }

  void _drag(DragUpdateDetails d) {
    if (!_dsc.isAttached || _avail <= 0) return;
    _dsc.jumpTo(
      (_dsc.size - d.delta.dy / _avail).clamp(CommentsPanel.min, 1.0),
    );
  }

  void _dragEnd(DragEndDetails d) {
    if (!_dsc.isAttached) return;
    final v = d.primaryVelocity ?? 0; // + = down
    final size = _dsc.size;
    double target;
    if (v > 800) {
      target = size > CommentsPanel.half + 0.05
          ? CommentsPanel.half
          : CommentsPanel.min;
    } else if (v < -800) {
      target = 1.0;
    } else if (size < (CommentsPanel.min + CommentsPanel.half) / 2) {
      target = CommentsPanel.min;
    } else if (size < (CommentsPanel.half + 1) / 2) {
      target = CommentsPanel.half;
    } else {
      target = 1.0;
    }
    _dsc.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final kb = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: kb),
      child: LayoutBuilder(
        builder: (context, box) {
          if (box.maxHeight != _avail) {
            _avail = box.maxHeight;
            WidgetsBinding.instance.addPostFrameCallback((_) => _report());
          }
          return NotificationListener<DraggableScrollableNotification>(
            onNotification: _onExtent,
            child: DraggableScrollableSheet(
              controller: _dsc,
              expand: false,
              initialChildSize: CommentsPanel.half,
              minChildSize: CommentsPanel.min,
              maxChildSize: 1,
              snap: true,
              snapSizes: const [CommentsPanel.half],
              shouldCloseOnMinExtent: true,
              builder: (context, scroll) => Material(
                key: const ValueKey('comments-panel'),
                color: AppColors.surface,
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(_full ? 0 : 22),
                ),
                child: CommentsSheet(
                  post: widget.post,
                  stream: widget.stream,
                  myUid: widget.myUid,
                  scrollController: scroll,
                  onHeaderDrag: _drag,
                  onHeaderDragEnd: _dragEnd,
                  topInset: _topInset,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Picture waiting to be sent with the next comment.
class _Draft {
  _Draft.file(File this.file, {required this.isGif}) : gif = null;
  _Draft.gif(PickedGif g) : file = null, gif = g.gif, isGif = true;

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
    this.scrollController,
    this.onHeaderDrag,
    this.onHeaderDragEnd,
    this.topInset,
  });
  final Post post;

  /// Tests: who is signed in.
  final String? myUid;

  /// From the draggable panel (null = fixed height sheet).
  final ScrollController? scrollController;
  final GestureDragUpdateCallback? onHeaderDrag;
  final GestureDragEndCallback? onHeaderDragEnd;

  /// Space for the status bar when the panel is full screen.
  final ValueListenable<double>? topInset;

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

  /// v0.11: the list has its OWN scroll controller, so scrolling comments
  /// never makes the panel full screen (only dragging the header does).
  final _list = ScrollController();

  /// v0.11: pinned comment id ('' = none).
  late String _pinned = widget.post.pinnedComment;
  bool _sending = false;
  Comment? _replyTo;
  _Draft? _draft;

  /// v0.9: one of your clips / posts sent with the comment.
  Post? _linked;
  final Set<String> _expanded = {};

  /// Replies shown before "View more replies".
  static const _repliesShown = 2;

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    _list.dispose();
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
        setState(() {
          _draft = _Draft.file(f, isGif: false);
          _linked = null;
        });
      }
    } catch (e) {
      if (mounted) _snack(friendlyError(e));
    }
  }

  Future<void> _pickGif() async {
    final g = await showGifPicker(context);
    if (g != null && mounted) {
      setState(() {
        _draft = _Draft.gif(g);
        _linked = null;
      });
    }
  }

  /// v0.10: ONE "+" button (like chats): photo, GIF, one of your posts /
  /// clips, or make a new clip / post as the answer.
  Future<void> _plus() async {
    final reply = _replyTo;
    final what = await showAttachMenu(
      context,
      const [
        AttachOption('photo', Icons.photo_outlined, 'Photo', AppColors.lime),
        AttachOption('gif', Icons.gif_box_outlined, 'GIF', AppColors.mint),
        AttachOption(
          'mine',
          Icons.grid_view_rounded,
          'My post / clip',
          Color(0xFFFFB86B),
        ),
        AttachOption(
          'new-clip',
          Icons.videocam_outlined,
          'New clip',
          Color(0xFFB794F6),
        ),
        AttachOption(
          'new-post',
          Icons.add_photo_alternate_outlined,
          'New post',
          Color(0xFF7FD4FF),
        ),
      ],
      keyPrefix: 'comment-attach',
      title: reply != null ? 'Reply to @${reply.authorUsername}' : null,
    );
    if (what == null || !mounted) return;
    switch (what) {
      case 'photo':
        await _pickPhoto();
      case 'gif':
        await _pickGif();
      case 'mine':
        final p = await showMyPostPicker(context);
        if (p != null && mounted) {
          setState(() {
            _linked = p;
            _draft = null;
          });
        }
      case 'new-clip':
      case 'new-post':
        final ref = reply != null
            ? ReplyRef.fromComment(widget.post, reply)
            : ReplyRef.toPost(widget.post);
        await startCompose(
          context,
          what == 'new-clip' ? ComposeMode.clip : ComposeMode.photo,
          reply: ref,
        );
    }
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
    final linked = _linked;
    final reply = _replyTo;
    // "@name " alone is not a comment
    if (reply != null && text == '@${reply.authorUsername}') text = '';
    if ((text.isEmpty && draft == null && linked == null) || _sending) return;
    // v0.18 Hyper Intelligence: no strong abuse
    if (!await hiTextOk(context, [text]) || !mounted) return;
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
        linked: linked,
      );
      _ctrl.clear();
      if (mounted) {
        setState(() {
          _draft = null;
          _linked = null;
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

  // ------------------------------------------------------- v0.11 menu

  /// Long-press a comment: Pin (post owner), Share, Report, Delete.
  Future<void> _commentMenu(
    Comment c, {
    required String me,
    required bool canModerate,
  }) async {
    final mine = c.authorId == me;
    final canPin = canModerate && !c.isReply;
    final pinned = c.id == _pinned;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) {
        Widget item(
          String id,
          IconData icon,
          String label, {
          bool danger = false,
        }) {
          final color = danger ? AppColors.like : AppColors.textPrimary;
          return ListTile(
            key: ValueKey('comment-menu-$id'),
            dense: true,
            leading: Icon(icon, color: color, size: 22),
            title: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            onTap: () => Navigator.pop(ctx, id),
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (canPin)
                item(
                  'pin',
                  pinned ? Icons.push_pin_outlined : Icons.push_pin,
                  pinned ? 'Unpin comment' : 'Pin comment',
                ),
              item('share', Icons.share_outlined, 'Share'),
              if (!mine)
                item('report', Icons.flag_outlined, 'Report', danger: true),
              if (mine || canModerate)
                item('delete', Icons.delete_outline, 'Delete', danger: true),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'pin':
        final next = pinned ? '' : c.id;
        final before = _pinned;
        setState(() => _pinned = next);
        try {
          await PostRepository.instance.pinComment(widget.post.id, next);
          _snack(next.isEmpty ? 'Comment unpinned' : 'Comment pinned');
        } catch (e) {
          if (mounted) {
            setState(() => _pinned = before);
            _snack(friendlyError(e));
          }
        }
      case 'share':
        await SharePlus.instance.share(
          ShareParams(text: commentShareText(widget.post, c)),
        );
      case 'report':
        await _report(c);
      case 'delete':
        await _delete(c);
    }
  }

  Future<void> _report(Comment c) async {
    var who = '', uid = '';
    try {
      final me = await UserRepository.instance.meCached();
      who = me.username;
      uid = me.uid;
    } catch (_) {}
    final mail = ReportRepository.commentEmail(
      post: widget.post,
      comment: c,
      reporterUsername: who,
      reporterUid: uid,
    );
    unawaited(
      ReportRepository.instance.save(
        ReportRepository.reportData(
          kind: 'comment',
          reporterUid: uid,
          reporterUsername: who,
          targetId: c.id,
          postId: widget.post.id,
          targetUid: c.authorId,
          reason: 'Comment',
          message: c.text,
        ),
      ),
    );
    if (!mounted) return;
    final ok = await openEmail(
      context,
      to: ReportRepository.to,
      subject: mail.subject,
      body: mail.body,
    );
    if (ok && mounted) _snack('Press Send in your email app to report it.');
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
    final groups = <(Comment, List<Comment>)>[];
    var i = 0;
    while (i < threaded.length) {
      final c = threaded[i++];
      final replies = <Comment>[];
      while (i < threaded.length && threaded[i].parentId == c.id) {
        replies.add(threaded[i++]);
      }
      groups.add((c, replies));
    }
    // v0.11: the pinned comment comes first
    final p = groups.indexWhere((g) => g.$1.id == _pinned);
    if (p > 0) groups.insert(0, groups.removeAt(p));
    for (final (c, replies) in groups) {
      out.add(c);
      final open = _expanded.contains(c.id);
      final shown = open ? replies.length : _repliesShown;
      out.addAll(replies.take(shown));
      if (replies.length > shown) {
        out.add(_MoreReplies(c.id, replies.length - shown));
      }
    }
    return out;
  }

  Widget _header() {
    final sheet = widget.scrollController;
    final h = _headerBody();
    if (sheet == null) return h;
    // The panel's own controller must stay attached to something (it moves
    // the panel); it is attached here, to the header, which can't scroll.
    return SingleChildScrollView(
      controller: sheet,
      physics: const NeverScrollableScrollPhysics(),
      child: h,
    );
  }

  Widget _headerBody() {
    final inset = widget.topInset;
    final drag = widget.onHeaderDrag != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: widget.onHeaderDrag,
      onVerticalDragEnd: widget.onHeaderDragEnd,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (inset != null)
            ValueListenableBuilder<double>(
              valueListenable: inset,
              builder: (context, v, _) => SizedBox(height: v),
            ),
          if (drag)
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 6),
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textHint,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              'Comments',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }

  /// Loading / empty / error inside the panel's scroll view (so dragging
  /// there still moves the panel).
  Widget _filler(Widget child) => ListView(
    controller: _list,
    children: [SizedBox(height: 260, child: Center(child: child))],
  );

  @override
  Widget build(BuildContext context) {
    final me = widget.myUid ?? UserRepository.instance.myUid;
    final canModerate = widget.post.authorId == me;
    final body = Column(
      children: [
        _header(),
        Expanded(
          child: StreamBuilder<List<Comment>>(
            stream: _stream,
            builder: (context, snap) {
              if (snap.hasError) return _filler(ErrorView(error: snap.error));
              if (!snap.hasData) return _filler(const LoadingView());
              final rows = _rows(snap.data!);
              if (rows.isEmpty) {
                return _filler(
                  const EmptyState(
                    icon: Icons.chat_bubble_outline,
                    title: 'No comments yet',
                    subtitle: 'Start the conversation.',
                  ),
                );
              }
              return ListView.builder(
                controller: _list,
                padding: const EdgeInsets.only(bottom: 8),
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
                            'View ${r.count} more '
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
                    pinned: c.id == _pinned && !c.isReply,
                    onReply: () => _reply(c),
                    onDelete: () => _delete(c),
                    onLongPress: () =>
                        _commentMenu(c, me: me, canModerate: canModerate),
                  );
                },
              );
            },
          ),
        ),
        _composer(),
      ],
    );
    if (widget.scrollController != null) return body;
    // old fixed sheet (tests, simple use)
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: body,
      ),
    );
  }

  // ---------------------------------------------------------------- composer

  Widget _composer() {
    final draft = _draft;
    final reply = _replyTo;
    final canSend =
        !_sending &&
        (_ctrl.text.trim().isNotEmpty || draft != null || _linked != null);
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
          if (_linked != null)
            Padding(
              key: const ValueKey('linked-draft'),
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
              child: Row(
                children: [
                  LinkedPostCard(
                    thumb: _linked!.coverUrl,
                    author: _linked!.authorUsername,
                    isClip: _linked!.isClip,
                    width: 46,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _linked!.isClip ? 'Your clip' : 'Your post',
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                  const Spacer(),
                  IconButton(
                    key: const ValueKey('linked-remove'),
                    tooltip: 'Remove',
                    onPressed: _sending
                        ? null
                        : () => setState(() => _linked = null),
                    icon: const Icon(Icons.close, size: 20),
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
                  key: const ValueKey('comment-plus'),
                  tooltip: 'Photo, GIF, clip or post',
                  onPressed: _sending ? null : _plus,
                  icon: const Icon(Icons.add_circle_outline, size: 26),
                ),
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
                      // v0.9: no outline (no white lines)
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
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
    this.onLongPress,
    this.pinned = false,
  });

  final String postId;
  final Comment comment;
  final bool canDelete;
  final VoidCallback onReply;
  final VoidCallback onDelete;

  /// v0.11: long-press menu (pin / share / report / delete).
  final VoidCallback? onLongPress;

  /// v0.11: "Pinned by author" above the comment.
  final bool pinned;

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
        comment: widget.comment,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _optimistic = null);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.comment;
    final reply = c.isReply;
    final pic = c.pictureUrl;
    // v0.18 Hyper Intelligence: sensitive comment -> "Tap to view"
    final blurred = HyperIntelligence.instance.blursComment(c);
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
          onLongPress:
              widget.onLongPress ?? (widget.canDelete ? widget.onDelete : null),
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
                      if (widget.pinned)
                        const Padding(
                          key: ValueKey('comment-pinned'),
                          padding: EdgeInsets.only(bottom: 2),
                          child: Row(
                            children: [
                              Icon(
                                Icons.push_pin,
                                size: 12,
                                color: AppColors.lime,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'Pinned by author',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: AppColors.lime,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '${c.authorUsername} ',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                            verifiedSpan(c.authorId, size: 13),
                            const TextSpan(text: ' '),
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
                      if (blurred)
                        GestureDetector(
                          key: ValueKey('hi-comment-${c.id}'),
                          onTap: () => setState(
                            () => HyperIntelligence.instance.revealComment(c),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.only(top: 2),
                            child: Text(
                              'Hidden by Hyper Intelligence · Tap to view',
                              style: TextStyle(
                                fontSize: 13,
                                fontStyle: FontStyle.italic,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      if (c.text.isNotEmpty && !blurred)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: _CommentText(text: c.text),
                        ),
                      if (pic.isNotEmpty && !blurred)
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
                      if (c.hasRef)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: LinkedPostCard(
                            key: ValueKey('comment-ref-${c.id}'),
                            thumb: c.refThumb,
                            author: c.refAuthor,
                            isClip: c.refPostType == Post.clip,
                            onTap: () => openPostById(context, c.refPostId),
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
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
  Widget build(BuildContext context) => TaggedText(
    text,
    mentionAtStart: true,
    style: const TextStyle(color: AppColors.textPrimary, fontSize: 14.5),
  );
}
