import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/errors.dart';
import '../core/l10n.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../models/post.dart';
import '../services/user_service.dart';

/// Where reports are sent.
const String kReportEmail = 'techlabs.hyper@gmail.com';

/// The email that opens when someone reports a clip.
Uri reportUri(Post post, {String reason = '', String details = ''}) {
  final kind = post.isClip ? 'clip' : 'post';
  final subject = 'Report: $kind ${post.id}${reason.isEmpty ? '' : ' ($reason)'}';
  final body =
      'I want to report this $kind.\n\n'
      '${reason.isEmpty ? '' : 'Reason: $reason\n'}'
      'What is wrong:\n${details.trim().isEmpty ? '(please write here)' : details.trim()}\n\n'
      '---\n'
      'Post id: ${post.id}\n'
      'Posted by: @${post.authorUsername} (${post.authorId})\n'
      'Link: ${post.isVideo ? post.videoUrl : post.imageUrl}\n';
  // encodeComponent writes spaces as %20; Uri(queryParameters:) would write "+", which mail
  // apps show as a plus sign.
  return Uri.parse(
    'mailto:$kReportEmail?subject=${Uri.encodeComponent(subject)}'
    '&body=${Uri.encodeComponent(body)}',
  );
}

const List<String> kReportReasons = [
  'Spam',
  'Nudity or sexual content',
  'Hate or harassment',
  'Violence',
  'Copyright',
  'Something else',
];

/// Report a clip: pick a reason, write what is wrong, then the email to the team opens with
/// the text already in it.
Future<void> showReportSheet(BuildContext context, Post post) async {
  final result = await showModalBottomSheet<({String reason, String text})>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _ReportForm(ctx: ctx),
  );
  if (result == null || !context.mounted) return;
  var opened = false;
  try {
    opened = await launchUrl(
      reportUri(post, reason: result.reason, details: result.text),
    );
  } catch (_) {
    opened = false;
  }
  if (!context.mounted) return;
  showToast(
    context,
    opened
        ? 'Press send in your email app to report it.'
        : 'No email app found. Write to $kReportEmail',
  );
}

class _ReportForm extends StatefulWidget {
  const _ReportForm({required this.ctx});
  final BuildContext ctx;

  @override
  State<_ReportForm> createState() => _ReportFormState();
}

class _ReportFormState extends State<_ReportForm> {
  final _text = TextEditingController();
  String _reason = kReportReasons.last;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ok = _text.text.trim().length >= 5;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr('Report'),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            Text(
              'Tell us what is wrong. It goes to $kReportEmail.',
              style: TextStyle(color: context.muted),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final r in kReportReasons)
                  ChoiceChip(
                    label: Text(r),
                    selected: _reason == r,
                    showCheckmark: false,
                    selectedColor: AppTheme.coral.withValues(alpha: 0.9),
                    labelStyle: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: _reason == r ? Colors.white : null,
                    ),
                    onSelected: (_) => setState(() => _reason = r),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('reportText'),
              controller: _text,
              maxLines: 4,
              minLines: 3,
              maxLength: 500,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Write your problem here...',
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('reportSend'),
                onPressed: ok
                    ? () => Navigator.pop(widget.ctx, (
                        reason: _reason,
                        text: _text.text.trim(),
                      ))
                    : null,
                child: Text(context.tr('Send')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small "Follow" / "Following" pill on the Clips screen (hidden on your own clips).
class ReelFollowPill extends StatefulWidget {
  const ReelFollowPill({super.key, required this.uid});
  final String uid;

  @override
  State<ReelFollowPill> createState() => _ReelFollowPillState();
}

class _ReelFollowPillState extends State<ReelFollowPill> {
  bool? _following;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ReelFollowPill old) {
    super.didUpdateWidget(old);
    if (old.uid != widget.uid) {
      _following = null;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final v = await UserService.instance.isFollowing(widget.uid);
      if (mounted) setState(() => _following = v);
    } catch (_) {
      if (mounted) setState(() => _following = false);
    }
  }

  Future<void> _toggle() async {
    if (_busy || _following == null) return;
    final target = !_following!;
    setState(() {
      _busy = true;
      _following = target;
    });
    try {
      if (target) {
        await UserService.instance.follow(widget.uid);
      } else {
        await UserService.instance.unfollow(widget.uid);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _following = !target);
        showToast(context, friendlyError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final following = _following ?? false;
    return GestureDetector(
      key: const ValueKey('reelFollow'),
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      child: Container(
        width: 78,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: following ? Colors.black38 : AppTheme.volt,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: following ? Colors.white70 : AppTheme.volt),
        ),
        child: Text(
          following ? 'Following' : 'Follow',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            color: following ? Colors.white : AppTheme.ink,
          ),
        ),
      ),
    );
  }
}

/// Soft shadow that keeps white icons and text readable on any video.
const List<Shadow> kReelShadow = [Shadow(blurRadius: 8, color: Colors.black54)];

/// A plain icon (no background) used on the Clips screen: back, sound and the action rail.
class ReelIconButton extends StatelessWidget {
  const ReelIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.label,
    this.color = Colors.white,
    this.size = 32,
    this.pop = false,
  });

  final IconData icon;
  final VoidCallback onTap;

  /// Small number or word under the icon.
  final String? label;
  final Color color;
  final double size;

  /// Makes the icon a little bigger (used for the liked heart).
  final bool pop;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 60,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 46,
              child: Center(
                child: AnimatedScale(
                  scale: pop ? 1.2 : 1,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutBack,
                  child: Icon(
                    icon,
                    size: size,
                    color: color,
                    shadows: kReelShadow,
                  ),
                ),
              ),
            ),
            if (label != null)
              Text(
                label!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  shadows: kReelShadow,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
