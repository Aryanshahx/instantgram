import 'package:flutter/material.dart';

import '../../../core/services/media_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/models/post.dart';
import '../../editor/edit_models.dart';
import '../../camera/camera_screen.dart';
import '../../editor/media_editor_screen.dart';

export '../../editor/edit_models.dart' show ComposeMode;

/// Where the photos / videos come from.
enum MediaSource { gallery, photo, video }

/// Bottom sheet opened by the "+" button. Tap Post / Clip / Moment and
/// its choices open right below it: Gallery, Take photo, Record video.
Future<void> showCreateSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _CreateSheet(
      onPick: (mode, source) async {
        Navigator.pop(ctx);
        await startCompose(context, mode, source: source);
      },
    ),
  );
}

class _CreateSheet extends StatefulWidget {
  const _CreateSheet({required this.onPick});
  final void Function(ComposeMode mode, MediaSource source) onPick;

  @override
  State<_CreateSheet> createState() => _CreateSheetState();
}

class _CreateSheetState extends State<_CreateSheet> {
  ComposeMode? _open;

  Widget _option(ComposeMode mode, IconData icon, String title, String sub) {
    final open = _open == mode;
    return _CreateOption(
      key: ValueKey('create-${mode.name}'),
      icon: icon,
      title: title,
      subtitle: sub,
      open: open,
      onTap: () => setState(() => _open = open ? null : mode),
      choices: _SourceChoices(
        keyPrefix: 'create-${mode.name}',
        onPick: (s) => widget.onPick(mode, s),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 12, top: 4),
              child: Text(
                'Create',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
              ),
            ),
            _option(
              ComposeMode.photo,
              Icons.grid_view_rounded,
              'Post',
              'Photos and videos on your profile',
            ),
            _option(
              ComposeMode.clip,
              Icons.smart_display_outlined,
              'Clip',
              'Short videos and photos, full screen',
            ),
            _option(
              ComposeMode.story,
              Icons.add_circle_outline,
              'Moment',
              'Photos or videos for 24 hours',
            ),
          ],
        ),
      ),
    );
  }
}

/// Gallery / Take photo / Record video in one row.
class _SourceChoices extends StatelessWidget {
  const _SourceChoices({required this.keyPrefix, required this.onPick});
  final String keyPrefix;
  final ValueChanged<MediaSource> onPick;

  @override
  Widget build(BuildContext context) {
    Widget chip(MediaSource s, IconData icon, String label) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            key: ValueKey('$keyPrefix-${s.name}'),
            borderRadius: BorderRadius.circular(14),
            onTap: () => onPick(s),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                children: [
                  Icon(icon, color: AppColors.lime, size: 22),
                  const SizedBox(height: 5),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      child: Row(
        children: [
          chip(MediaSource.gallery, Icons.photo_library_outlined, 'Gallery'),
          chip(MediaSource.photo, Icons.photo_camera_outlined, 'Take photo'),
          chip(MediaSource.video, Icons.videocam_outlined, 'Record video'),
        ],
      ),
    );
  }
}

/// Small sheet with the same three choices (replies, "Use this audio").
Future<MediaSource?> showMediaSourceSheet(BuildContext context) {
  return showModalBottomSheet<MediaSource>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const ValueKey('pick-gallery'),
            leading: const Icon(
              Icons.photo_library_outlined,
              color: AppColors.lime,
            ),
            title: const Text('Choose photos or videos'),
            subtitle: const Text('Pick as many as you like'),
            onTap: () => Navigator.pop(ctx, MediaSource.gallery),
          ),
          ListTile(
            key: const ValueKey('pick-photo'),
            leading: const Icon(
              Icons.photo_camera_outlined,
              color: AppColors.lime,
            ),
            title: const Text('Take photo'),
            onTap: () => Navigator.pop(ctx, MediaSource.photo),
          ),
          ListTile(
            key: const ValueKey('pick-video'),
            leading: const Icon(Icons.videocam_outlined, color: AppColors.lime),
            title: const Text('Record video'),
            subtitle: const Text('Filters, music, length and more'),
            onTap: () => Navigator.pop(ctx, MediaSource.video),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Pick media -> editor -> share screen.
/// Posts and clips can mix photos and videos (no limit).
/// v0.9: [reply] = the new clip / post answers a comment.
/// Music update: [audio] = "Use this audio" (the editor starts with it).
/// [source] = already chosen (create sheet); null = ask first.
Future<void> startCompose(
  BuildContext context,
  ComposeMode mode, {
  ReplyRef? reply,
  PickedAudio? audio,
  MediaSource? source,
}) async {
  final src = source ?? await showMediaSourceSheet(context);
  if (src == null || !context.mounted) return;
  ComposeReply.pending = mode == ComposeMode.story ? null : reply;
  try {
    if (src == MediaSource.gallery) {
      final media = await MediaService.instance.pickGallery(context);
      if (media.isEmpty || !context.mounted) return;
      await openEditor(context, media, mode, audio: audio);
      return;
    }
    final r = await openCamera(
      context,
      mode: mode,
      video: src == MediaSource.video,
      audio: audio,
    );
    if (r == null || r.media.isEmpty || !context.mounted) return;
    await openEditor(context, r.media, mode, audio: r.audio ?? audio);
  } finally {
    ComposeReply.pending = null;
  }
}

/// The comment the clip / post being made answers (v0.9).
class ComposeReply {
  ComposeReply._();
  static ReplyRef? pending;
}

class _CreateOption extends StatelessWidget {
  const _CreateOption({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.open,
    required this.choices,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool open;
  final Widget choices;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.background,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: open ? AppColors.lime : AppColors.border),
        ),
        child: Column(
          children: [
            ListTile(
              onTap: onTap,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.lime,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: Colors.black),
              ),
              title: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                ),
              ),
              subtitle: Text(
                subtitle,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              trailing: AnimatedRotation(
                turns: open ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(
                  Icons.keyboard_arrow_down,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: open ? choices : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}
