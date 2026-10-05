import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/errors.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../models/post.dart';
import '../services/user_service.dart';

/// Where reports are sent.
const String kReportEmail = 'techlabs.hyper@gmail.com';

/// The email that opens when someone reports a clip.
Uri reportUri(Post post) {
  final kind = post.isClip ? 'clip' : 'post';
  final subject = 'Report: $kind ${post.id}';
  final body =
      'I want to report this $kind.\n\n'
      'Post id: ${post.id}\n'
      'Posted by: @${post.authorUsername} (${post.authorId})\n'
      'Link: ${post.isVideo ? post.videoUrl : post.imageUrl}\n\n'
      'Reason (please write here):\n';
  // encodeComponent writes spaces as %20; Uri(queryParameters:) would write "+", which mail
  // apps show as a plus sign.
  return Uri.parse(
    'mailto:$kReportEmail?subject=${Uri.encodeComponent(subject)}'
    '&body=${Uri.encodeComponent(body)}',
  );
}

/// The "..." menu of a clip: report it (opens an email to the team).
Future<void> showReportSheet(BuildContext context, Post post) async {
  final report = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const ValueKey('reportClip'),
            leading: const Icon(Icons.flag_outlined, color: AppTheme.coral),
            title: const Text(
              'Report',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: AppTheme.coral,
              ),
            ),
            subtitle: Text('Sends an email to $kReportEmail'),
            onTap: () => Navigator.pop(ctx, true),
          ),
          ListTile(
            leading: const Icon(Icons.close_rounded),
            title: const Text('Cancel'),
            onTap: () => Navigator.pop(ctx, false),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (report != true || !context.mounted) return;
  var opened = false;
  try {
    opened = await launchUrl(reportUri(post));
  } catch (_) {
    opened = false;
  }
  if (!opened && context.mounted) {
    showToast(context, 'No email app found. Write to $kReportEmail');
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
