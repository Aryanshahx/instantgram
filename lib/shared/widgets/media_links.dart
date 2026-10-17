import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../models/post.dart';

/// v0.0.2: the link sticker (like Instagram): 🔗 + name.
/// [frameWidth] = width of the photo / video it sits on.
class MediaLinkChip extends StatelessWidget {
  const MediaLinkChip({
    super.key,
    required this.link,
    required this.frameWidth,
  });

  final MediaLink link;
  final double frameWidth;

  @override
  Widget build(BuildContext context) {
    final fs = (frameWidth * 0.036).clamp(10.0, 17.0);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: frameWidth * 0.8),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: fs * 0.75, vertical: fs * 0.45),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(fs * 0.6),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.link_rounded, size: fs * 1.25, color: const Color(0xFF2F6BFF)),
            SizedBox(width: fs * 0.3),
            Flexible(
              child: Text(
                link.shown,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  color: const Color(0xFF2F6BFF),
                  fontSize: fs,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// v0.0.2: link stickers on top of a photo / video shown with [fit] in
/// this box ([aspect] = the media's width / height). Tap = open.
class MediaLinksLayer extends StatelessWidget {
  const MediaLinksLayer({
    super.key,
    required this.links,
    required this.aspect,
    this.fit = BoxFit.contain,
    this.onOpen,
  });

  final List<MediaLink> links;
  final double aspect;
  final BoxFit fit;

  /// Tests (default: [openMediaLink]).
  final void Function(BuildContext context, MediaLink link)? onOpen;

  /// Where the media is drawn inside [box].
  static Rect mediaRect(Size box, double aspect, BoxFit fit) {
    final a = safeAspect(aspect);
    final fitted = applyBoxFit(fit, Size(a * 1000, 1000), box);
    return Alignment.center.inscribe(fitted.destination, Offset.zero & box);
  }

  @override
  Widget build(BuildContext context) {
    if (links.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, box) {
        final r = mediaRect(box.biggest, aspect, fit);
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            for (var i = 0; i < links.length; i++)
              Positioned(
                left: r.left + links[i].x * r.width,
                top: r.top + links[i].y * r.height,
                child: FractionalTranslation(
                  translation: const Offset(-0.5, -0.5),
                  child: GestureDetector(
                    key: ValueKey('media-link-$i'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        (onOpen ?? openMediaLink)(context, links[i]),
                    child: MediaLinkChip(link: links[i], frameWidth: r.width),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Puts the link stickers of [item] over [media] (same box).
Widget withMediaLinks(
  Widget media,
  MediaItem item, {
  BoxFit fit = BoxFit.contain,
  double? aspect,
}) {
  if (item.links.isEmpty) return media;
  return Stack(
    fit: StackFit.expand,
    children: [
      media,
      MediaLinksLayer(
        links: item.links,
        aspect: aspect ?? item.aspectRatio,
        fit: fit,
      ),
    ],
  );
}

/// v0.0.2: "Open this link?" (shows the full address first), then opens
/// it in the browser.
Future<void> openMediaLink(
  BuildContext context,
  MediaLink link, {
  Future<bool> Function(Uri uri)? launch,
}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: AppColors.surface,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.link_rounded, color: AppColors.lime),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    link.shown,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              link.url,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'This link goes outside InstantGram.',
              style: TextStyle(color: AppColors.textHint, fontSize: 12),
            ),
            const SizedBox(height: 14),
            FilledButton(
              key: const ValueKey('media-link-open'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.lime,
                foregroundColor: Colors.black,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                'Open link',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    ),
  );
  if (ok != true) return;
  final uri = Uri.parse(link.url);
  final opened = await (launch ??
      (u) => launchUrl(u, mode: LaunchMode.externalApplication))(uri);
  if (!opened && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Could not open the link')),
    );
  }
}

/// Result of the link editor.
class MediaLinkEdit {
  const MediaLinkEdit({this.link, this.delete = false});
  final MediaLink? link;
  final bool delete;
}

/// v0.0.2: editor "Link" box: address + optional sticker text.
/// null = cancelled.
Future<MediaLinkEdit?> showMediaLinkEditor(
  BuildContext context, {
  MediaLink? link,
}) {
  return showDialog<MediaLinkEdit>(
    context: context,
    builder: (_) => _LinkDialog(link: link),
  );
}

class _LinkDialog extends StatefulWidget {
  const _LinkDialog({this.link});
  final MediaLink? link;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final _url = TextEditingController(text: widget.link?.url ?? '');
  late final _label = TextEditingController(text: widget.link?.label ?? '');
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _label.dispose();
    super.dispose();
  }

  void _save() {
    final url = MediaLink.clean(_url.text);
    if (url == null) {
      setState(() => _error = 'Enter a website, like example.com');
      return;
    }
    var label = _label.text.trim();
    if (label.length > MediaLink.maxLabel) {
      label = label.substring(0, MediaLink.maxLabel);
    }
    final old = widget.link;
    Navigator.pop(
      context,
      MediaLinkEdit(
        link: old == null
            ? MediaLink(url: url, label: label)
            : old.copyWith(url: url, label: label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.link == null ? 'Add link' : 'Edit link'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('link-url'),
            controller: _url,
            autofocus: true,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              hintText: 'https://example.com',
              prefixIcon: const Icon(Icons.link_rounded),
              errorText: _error,
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('link-label'),
            controller: _label,
            maxLength: MediaLink.maxLabel,
            decoration: const InputDecoration(
              hintText: 'Sticker text (optional)',
              prefixIcon: Icon(Icons.short_text),
            ),
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        if (widget.link != null)
          TextButton(
            key: const ValueKey('link-remove'),
            onPressed: () =>
                Navigator.pop(context, const MediaLinkEdit(delete: true)),
            child: const Text(
              'Remove',
              style: TextStyle(color: AppColors.like),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('link-save'),
          onPressed: _save,
          child: const Text(
            'Done',
            style: TextStyle(color: AppColors.lime),
          ),
        ),
      ],
    );
  }
}
