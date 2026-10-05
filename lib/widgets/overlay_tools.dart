import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/finish.dart';
import '../models/story.dart';
import 'story_overlays.dart';

/// Text and sticker tools shared by the moment composer and the post editor.

const kOverlayColors = <int>[
  0xFFFFFFFF,
  0xFF0B0D12,
  0xFFD2FF3F,
  0xFF4DF0B4,
  0xFFFF5C6C,
  0xFF7B6CFF,
  0xFFFFD43B,
];

const kOverlayEmojis = [
  '😀',
  '😂',
  '😍',
  '🥰',
  '😎',
  '🤩',
  '😭',
  '😡',
  '🔥',
  '💯',
  '❤️',
  '💜',
  '💚',
  '✨',
  '🎉',
  '🥳',
  '👍',
  '👏',
  '🙌',
  '🙏',
  '💪',
  '👀',
  '🎶',
  '🎧',
  '🌈',
  '☀️',
  '🌙',
  '⭐',
  '🌸',
  '🍕',
  '🍔',
  '☕',
  '📍',
  '✈️',
  '🏖️',
  '⚽',
  '🎮',
  '📸',
  '💥',
  '🚀',
];

/// Asks for a text (and its colour and box). Returns the overlay, with an empty text when the
/// person chose Remove; null when the sheet was dismissed.
Future<StoryOverlay?> showOverlayTextSheet(
  BuildContext context,
  StoryOverlay start, {
  bool canDelete = false,
}) {
  return showModalBottomSheet<StoryOverlay>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _OverlayTextSheet(start: start, canDelete: canDelete),
  );
}

/// A grid of emoji; returns the chosen one.
Future<String?> showEmojiSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: GridView.count(
          shrinkWrap: true,
          crossAxisCount: 8,
          children: [
            for (final e in kOverlayEmojis)
              InkWell(
                key: ValueKey('emoji_$e'),
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.pop(ctx, e),
                child: Center(
                  child: Text(e, style: const TextStyle(fontSize: 28)),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Drags, pinches and taps the texts and stickers on a picture of any shape. Positions and
/// sizes are fractions of the picture, so they look the same everywhere.
class OverlayEditLayer extends StatefulWidget {
  const OverlayEditLayer({
    super.key,
    required this.overlays,
    required this.onChanged,
    required this.onTap,
  });

  final List<StoryOverlay> overlays;
  final ValueChanged<List<StoryOverlay>> onChanged;
  final void Function(int index) onTap;

  @override
  State<OverlayEditLayer> createState() => _OverlayEditLayerState();
}

class _OverlayEditLayerState extends State<OverlayEditLayer> {
  double _baseScale = 1;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final h = box.maxHeight;
        final list = widget.overlays;
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            for (var i = 0; i < list.length; i++)
              Positioned(
                key: ValueKey('overlay$i'),
                left: list[i].dx * w,
                top: list[i].dy * h,
                child: FractionalTranslation(
                  translation: const Offset(-0.5, -0.5),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: w * 0.92),
                    child: GestureDetector(
                      key: ValueKey('drag$i'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => widget.onTap(i),
                      onScaleStart: (_) => _baseScale = list[i].scale,
                      onScaleUpdate: (d) {
                        final o = list[i];
                        final next = [...list];
                        next[i] = o.copyWith(
                          dx: (o.dx + d.focalPointDelta.dx / w).clamp(0.02, 0.98),
                          dy: (o.dy + d.focalPointDelta.dy / h).clamp(0.02, 0.98),
                          scale: d.pointerCount > 1
                              ? (_baseScale * d.scale).clamp(0.4, 4.0)
                              : o.scale,
                        );
                        widget.onChanged(next);
                      },
                      child: StoryOverlayChip(overlay: list[i], canvasWidth: w),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A video (or any picture) with its colour look and its texts and stickers on top.
class FinishedMedia extends StatelessWidget {
  const FinishedMedia({super.key, required this.finish, required this.child});
  final MediaFinish? finish;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final f = finish;
    if (f == null || f.isEmpty) return child;
    final look = f.look;
    final colored = look == null || look.isEmpty
        ? child
        : ColorFiltered(colorFilter: lookFilter(look), child: child);
    return OverlayShow(overlays: f.overlays, child: colored);
  }
}

/// Texts and stickers drawn over a photo or clip when people look at it (no touch handling).
class OverlayShow extends StatelessWidget {
  const OverlayShow({super.key, required this.overlays, required this.child});
  final List<StoryOverlay> overlays;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (overlays.isEmpty) return child;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (context, box) {
                final w = box.maxWidth;
                final h = box.maxHeight;
                return ClipRect(
                  child: Stack(
                    children: [
                      for (final o in overlays)
                        Positioned(
                          left: o.dx * w,
                          top: o.dy * h,
                          child: FractionalTranslation(
                            translation: const Offset(-0.5, -0.5),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: w * 0.92),
                              child: StoryOverlayChip(overlay: o, canvasWidth: w),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _OverlayTextSheet extends StatefulWidget {
  const _OverlayTextSheet({required this.start, required this.canDelete});
  final StoryOverlay start;
  final bool canDelete;

  @override
  State<_OverlayTextSheet> createState() => _OverlayTextSheetState();
}

class _OverlayTextSheetState extends State<_OverlayTextSheet> {
  late final TextEditingController _c = TextEditingController(
    text: widget.start.text,
  );
  late int _color = widget.start.color;
  late bool _pill = widget.start.pill;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  StoryOverlay get _result =>
      widget.start.copyWith(text: _c.text.trim(), color: _color, pill: _pill);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
        left: 20,
        right: 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('storyTextInput'),
            controller: _c,
            autofocus: true,
            maxLength: 120,
            maxLines: 3,
            minLines: 1,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Type something...'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final c in kOverlayColors)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Container(
                    width: 32,
                    height: 32,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: Color(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: c == _color ? AppTheme.violet : Colors.grey,
                        width: c == _color ? 3 : 1,
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              FilterChip(
                key: const ValueKey('storyPill'),
                label: const Text('Box'),
                selected: _pill,
                onSelected: (v) => setState(() => _pill = v),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (widget.canDelete)
                TextButton(
                  key: const ValueKey('storyTextDelete'),
                  onPressed: () =>
                      Navigator.pop(context, widget.start.copyWith(text: '')),
                  child: const Text(
                    'Remove',
                    style: TextStyle(color: AppTheme.coral),
                  ),
                ),
              const Spacer(),
              FilledButton(
                key: const ValueKey('storyTextDone'),
                style: FilledButton.styleFrom(minimumSize: const Size(110, 46)),
                onPressed: () => Navigator.pop(context, _result),
                child: const Text('Done'),
              ),
            ],
          ),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}
