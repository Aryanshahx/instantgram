import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/services/content_filter.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/share.dart';
import '../../../shared/models/post.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/ig_text_field.dart';
import '../../post/data/post_repository.dart';
import '../data/chat_repository.dart';
import '../../../shared/widgets/verified_badge.dart';

/// Loads who you can share with (tests replace this).
typedef ShareTargetsLoader = Future<List<ChatPerson>> Function();

/// Sends a post to someone (tests replace this).
typedef SharePostSender = Future<void> Function(ChatPerson to, Post post);

/// In-app share sheet: people you chat with + people you follow,
/// a search box, "Copy link" and "More apps".
Future<void> showShareSheet(
  BuildContext context,
  Post post, {
  ShareTargetsLoader? loadTargets,
  SharePostSender? send,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) => ShareSheet(
      post: post,
      loadTargets: loadTargets ?? ChatRepository.instance.shareTargets,
      send:
          send ??
          (to, p) async {
            await ChatRepository.instance.sendPost(to, p);
            await PostRepository.instance.addShare(p);
          },
    ),
  );
}

class ShareSheet extends StatefulWidget {
  const ShareSheet({
    super.key,
    required this.post,
    required this.loadTargets,
    required this.send,
  });

  final Post post;
  final ShareTargetsLoader loadTargets;
  final SharePostSender send;

  @override
  State<ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<ShareSheet> {
  late final Future<List<ChatPerson>> _targets = widget.loadTargets();
  final _search = TextEditingController();
  String _q = '';
  final Set<String> _sent = {};
  final Set<String> _sending = {};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _send(ChatPerson p) async {
    if (_sent.contains(p.uid) || _sending.contains(p.uid)) return;
    setState(() => _sending.add(p.uid));
    try {
      await widget.send(p, widget.post);
      if (mounted) setState(() => _sent.add(p.uid));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _sending.remove(p.uid));
    }
  }

  Future<void> _copyLink() async {
    await Clipboard.setData(ClipboardData(text: postLink(widget.post)));
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    messenger?.showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  void _moreApps() {
    final post = widget.post;
    Navigator.of(context).pop();
    shareToOtherApps(post);
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: h * 0.62,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: IgTextField(
                key: const ValueKey('share-search'),
                hint: 'Search',
                icon: Icons.search,
                height: 42,
                controller: _search,
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<ChatPerson>>(
                future: _targets,
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    );
                  }
                  final blocked = ContentFilter.instance;
                  final list = snap.data!
                      .where((p) => !blocked.isBlocked(p.uid) && p.matches(_q))
                      .toList();
                  if (list.isEmpty) {
                    return Center(
                      child: Text(
                        snap.data!.isEmpty
                            ? 'Follow people or start a chat to share here.'
                            : 'Nobody found',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.only(top: 4),
                    itemCount: list.length,
                    itemBuilder: (context, i) => _row(list[i]),
                  );
                },
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _Action(
                      key: const ValueKey('share-copy'),
                      icon: Icons.link,
                      label: 'Copy link',
                      onTap: _copyLink,
                    ),
                    _Action(
                      key: const ValueKey('share-more'),
                      icon: Icons.ios_share,
                      label: 'More apps',
                      onTap: _moreApps,
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

  Widget _row(ChatPerson p) {
    final sent = _sent.contains(p.uid);
    final sending = _sending.contains(p.uid);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Row(
        children: [
          Avatar(url: p.photoUrl, name: p.username, size: 40, uid: p.uid),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NameBadge(
                  p.username,
                  uid: p.uid,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                  ),
                ),
                if (p.name.isNotEmpty || p.recent)
                  Text(
                    p.recent ? 'Recent chat' : p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: 32,
            child: FilledButton(
              key: ValueKey('share-send-${p.uid}'),
              onPressed: sent || sending ? null : () => _send(p),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.lime,
                foregroundColor: Colors.black,
                disabledBackgroundColor: AppColors.surfaceHigh,
                disabledForegroundColor: AppColors.textSecondary,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                textStyle: const TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              child: Text(sent ? 'Sent' : (sending ? '...' : 'Send')),
            ),
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: const BoxDecoration(
                color: AppColors.surfaceHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 22),
            ),
            const SizedBox(height: 5),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
