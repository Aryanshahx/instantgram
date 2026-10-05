import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_events.dart';
import '../core/errors.dart';
import '../core/l10n.dart';
import '../core/share.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../models/post.dart';
import '../services/post_service.dart';
import '../services/user_service.dart';
import 'post_details_sheet.dart';
import 'reel_actions.dart';
import 'share_sheet.dart';

/// What a long press (or the three dots) on a post offers.
/// Mine: Analytics, Pin, Share, Copy link, Delete. Someone else's: Repost, Report, Share, Copy link.
Future<void> showPostActions(
  BuildContext context,
  Post post, {
  VoidCallback? onChanged,
  VoidCallback? onDeleted,
  String? myUid,
  Future<bool> Function(String id)? isReposted,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => _ActionsSheet(
      post: post,
      onChanged: onChanged,
      onDeleted: onDeleted,
      host: context,
      myUid: myUid,
      isReposted: isReposted,
    ),
  );
}

class _ActionsSheet extends StatefulWidget {
  const _ActionsSheet({
    required this.post,
    required this.host,
    this.onChanged,
    this.onDeleted,
    this.myUid,
    this.isReposted,
  });
  final Post post;

  /// The screen that opened the sheet (the sheet's own context is gone after it closes).
  final BuildContext host;
  final VoidCallback? onChanged;
  final VoidCallback? onDeleted;

  /// Who is signed in, and whether they reposted a post (tests pass their own).
  final String? myUid;
  final Future<bool> Function(String id)? isReposted;

  @override
  State<_ActionsSheet> createState() => _ActionsSheetState();
}

class _ActionsSheetState extends State<_ActionsSheet> {
  late final bool _pinned = widget.post.pinned;
  bool _reposted = false;
  bool _busy = false;

  Post get post => widget.post;
  bool get _mine =>
      post.authorId == (widget.myUid ?? UserService.instance.myUid);

  @override
  void initState() {
    super.initState();
    if (!_mine) {
      (widget.isReposted ?? PostService.instance.isReposted)(post.id).then((v) {
        if (mounted) setState(() => _reposted = v);
      }).catchError((_) {});
    }
  }

  void _close() => Navigator.of(context).pop();

  Future<void> _pin() async {
    if (_busy) return;
    setState(() => _busy = true);
    final host = widget.host;
    final target = !_pinned;
    try {
      await PostService.instance.setPinned(post, target);
      widget.onChanged?.call();
      AppEvents.refreshFeed();
      _close();
      if (host.mounted) {
        showToast(host, target ? 'Pinned to the top of your profile' : 'Unpinned');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, e is PinLimitException ? e.message : friendlyError(e));
    }
  }

  Future<void> _repost() async {
    if (_busy) return;
    setState(() => _busy = true);
    final host = widget.host;
    final target = !_reposted;
    try {
      await PostService.instance.setReposted(post, target);
      widget.onChanged?.call();
      AppEvents.refreshFeed();
      _close();
      if (host.mounted) {
        showToast(host, target ? 'Reposted to your profile' : 'Repost removed');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, friendlyError(e));
    }
  }

  Future<void> _delete() async {
    final host = widget.host;
    _close();
    final ok = await confirm(
      host,
      title: 'Delete post?',
      message: 'This cannot be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !host.mounted) return;
    try {
      await PostService.instance.deletePost(post);
      widget.onDeleted?.call();
      widget.onChanged?.call();
      AppEvents.refreshFeed();
    } catch (e) {
      if (host.mounted) showToast(host, friendlyError(e));
    }
  }

  Future<void> _copy() async {
    final host = widget.host;
    await Clipboard.setData(ClipboardData(text: shareLinkFor(post)));
    _close();
    if (host.mounted) showToast(host, 'Link copied');
  }

  @override
  Widget build(BuildContext context) {
    Widget tile(
      Key key,
      IconData icon,
      String label,
      VoidCallback onTap, {
      Color? color,
    }) => ListTile(
      key: key,
      leading: Icon(icon, color: color),
      title: Text(
        context.tr(label),
        style: TextStyle(fontWeight: FontWeight.w700, color: color),
      ),
      onTap: onTap,
    );

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_mine) ...[
              tile(const ValueKey('actAnalytics'), Icons.insights_rounded, 'Analytics', () {
                final host = widget.host;
                _close();
                showPostDetails(host, post);
              }),
              tile(
                const ValueKey('actPin'),
                _pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
                _pinned ? 'Unpin' : 'Pin',
                _pin,
              ),
            ] else ...[
              tile(
                const ValueKey('actRepost'),
                Icons.repeat_rounded,
                _reposted ? 'Reposted' : 'Repost',
                _repost,
                color: _reposted ? context.accentInk : null,
              ),
              tile(const ValueKey('actReport'), Icons.flag_outlined, 'Report', () {
                final host = widget.host;
                _close();
                showReportSheet(host, post);
              }),
            ],
            tile(const ValueKey('actShare'), Icons.ios_share_rounded, 'Share', () {
              final host = widget.host;
              _close();
              showShareSheet(host, post);
            }),
            tile(const ValueKey('actCopy'), Icons.link_rounded, 'Copy link', _copy),
            if (_mine)
              tile(
                const ValueKey('actDelete'),
                Icons.delete_outline_rounded,
                'Delete',
                _delete,
                color: AppTheme.coral,
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
