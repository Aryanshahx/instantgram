import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/errors.dart';
import '../../../shared/models/post.dart';
import '../../../core/services/app_settings.dart';
import '../../../core/services/content_filter.dart';
import '../data/post_repository.dart';
import '../../insights/post_insights_screen.dart';
import 'report_sheet.dart';

/// "..." menu for a post or clip.
/// [showAutoScroll] adds the "Auto scroll" switch (Clips screen).
Future<void> showPostMenu(
  BuildContext context,
  Post post, {
  VoidCallback? onDeleted,
  bool showAutoScroll = false,
}) {
  final mine = post.authorId == ContentFilter.instance.uid;
  final messenger = ScaffoldMessenger.of(context);
  final settings = AppSettings.instance;
  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListTileTheme.merge(
        visualDensity: VisualDensity.compact,
        iconColor: AppColors.textPrimary,
        titleTextStyle: const TextStyle(
          fontFamily: AppTheme.fontFamily,
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: AppColors.textPrimary,
        ),
        subtitleTextStyle: const TextStyle(
          fontFamily: AppTheme.fontFamily,
          fontSize: 12.5,
          color: AppColors.textSecondary,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showAutoScroll)
              ValueListenableBuilder<bool>(
                valueListenable: settings.clipsAutoScroll,
                builder: (context, on, child) => SwitchListTile(
                  secondary: const Icon(Icons.swipe_up_outlined),
                  title: const Text('Auto scroll'),
                  subtitle: const Text('Play the next clip when one ends'),
                  value: on,
                  activeThumbColor: Colors.black,
                  activeTrackColor: AppColors.lime,
                  onChanged: settings.setClipsAutoScroll,
                ),
              ),
            // not on the Clips screen (no analytics there)
            if (mine && !showAutoScroll)
              ListTile(
                key: const ValueKey('menu-analytics'),
                leading: const Icon(Icons.insights_outlined),
                title: const Text('Analytics'),
                onTap: () {
                  Navigator.pop(ctx);
                  openPostInsights(context, post);
                },
              ),
            if (mine)
              ListTile(
                leading: Icon(
                  post.pinned ? Icons.push_pin_outlined : Icons.push_pin,
                ),
                title: Text(
                  post.pinned ? 'Unpin from profile' : 'Pin to profile',
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await PostRepository.instance.setPinned(post, !post.pinned);
                  } catch (e) {
                    messenger.showSnackBar(
                      SnackBar(content: Text(friendlyError(e))),
                    );
                  }
                },
              ),
            if (mine)
              ListTile(
                key: const ValueKey('menu-options'),
                leading: const Icon(Icons.tune),
                title: const Text('Audience and counts'),
                subtitle: Text(Audience.label(post.audience)),
                onTap: () {
                  Navigator.pop(ctx);
                  showPostOptionsSheet(context, post);
                },
              ),
            if (!mine)
              ListTile(
                leading: const Icon(Icons.flag_outlined, color: AppColors.like),
                title: Text(
                  'Report ${post.isClip ? 'clip' : 'post'}',
                  style: const TextStyle(color: AppColors.like),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  showReportSheet(context, post);
                },
              ),
            if (mine)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: AppColors.like,
                ),
                title: const Text(
                  'Delete',
                  style: TextStyle(color: AppColors.like),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: Text(
                        'Delete this ${post.isClip ? 'clip' : 'post'}?',
                      ),
                      content: const Text('This cannot be undone.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(d, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(d, true),
                          child: const Text(
                            'Delete',
                            style: TextStyle(color: AppColors.like),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (ok != true) return;
                  try {
                    await PostRepository.instance.delete(post);
                    onDeleted?.call();
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Deleted')),
                    );
                  } catch (e) {
                    messenger.showSnackBar(
                      SnackBar(content: Text(friendlyError(e))),
                    );
                  }
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

/// Owner: change audience and hidden counts after posting.
Future<void> showPostOptionsSheet(BuildContext context, Post post) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _PostOptionsSheet(post: post),
  );
}

class _PostOptionsSheet extends StatefulWidget {
  const _PostOptionsSheet({required this.post});
  final Post post;

  @override
  State<_PostOptionsSheet> createState() => _PostOptionsSheetState();
}

class _PostOptionsSheetState extends State<_PostOptionsSheet> {
  late String _audience = widget.post.audience;
  late bool _likes = widget.post.hideLikes;
  late bool _comments = widget.post.hideComments;
  late bool _reposts = widget.post.hideReposts;
  late bool _shares = widget.post.hideShares;
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    try {
      await PostRepository.instance.updateOptions(widget.post, {
        'audience': _audience,
        'hideLikes': _likes,
        'hideComments': _comments,
        'hideReposts': _reposts,
        'hideShares': _shares,
      });
      nav.pop();
      messenger.showSnackBar(const SnackBar(content: Text('Saved')));
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  Widget _switch(String title, bool v, ValueChanged<bool> on) => SwitchListTile(
    dense: true,
    title: Text(
      title,
      style: const TextStyle(
        fontFamily: AppTheme.fontFamily,
        fontSize: 14.5,
        fontWeight: FontWeight.w600,
      ),
    ),
    value: v,
    activeThumbColor: Colors.black,
    activeTrackColor: AppColors.lime,
    onChanged: (x) => setState(() => on(x)),
  );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                'Who can see this',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
            for (final a in Audience.all)
              ListTile(
                dense: true,
                leading: Icon(switch (a) {
                  Audience.followers => Icons.people_outline,
                  Audience.onlyMe => Icons.lock_outline,
                  _ => Icons.public,
                }),
                title: Text(
                  Audience.label(a),
                  style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                trailing: _audience == a
                    ? const Icon(Icons.check_circle, color: AppColors.lime)
                    : const Icon(
                        Icons.circle_outlined,
                        color: AppColors.textSecondary,
                      ),
                onTap: () => setState(() => _audience = a),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Text(
                'HIDE COUNTS FROM OTHERS',
                style: TextStyle(
                  fontSize: 11.5,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            _switch('Hide like count', _likes, (x) => _likes = x),
            _switch('Hide comment count', _comments, (x) => _comments = x),
            _switch('Hide repost count', _reposts, (x) => _reposts = x),
            _switch('Hide share count', _shares, (x) => _shares = x),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                height: 46,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.lime,
                    foregroundColor: Colors.black,
                    textStyle: const TextStyle(
                      fontFamily: AppTheme.fontFamily,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
