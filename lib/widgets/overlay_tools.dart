import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../core/l10n.dart';
import '../core/theme.dart';
import '../services/giphy.dart';
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

/// Tests set this so the sheet does not depend on the Giphy key of the machine.
@visibleForTesting
GiphyClient? debugStickerClient;

/// The sticker sheet: real stickers from Giphy (animated on clips and moments, one frame
/// when baked into a photo) and, on a second tab, emoji. Returns the finished overlay.
/// Without a Giphy key only the emoji tab is shown.
Future<StoryOverlay?> showStickerSheet(
  BuildContext context, {
  GiphyClient? client,
}) {
  final giphy = client ?? debugStickerClient ?? GiphyClient(stickers: true);
  return showModalBottomSheet<StoryOverlay>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.75,
      child: StickerSheet(client: giphy),
    ),
  );
}

class StickerSheet extends StatefulWidget {
  const StickerSheet({super.key, required this.client});
  final GiphyClient client;

  @override
  State<StickerSheet> createState() => _StickerSheetState();
}

class _StickerSheetState extends State<StickerSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: widget.client.configured ? 2 : 1,
    vsync: this,
  );
  final _q = TextEditingController();
  Timer? _debounce;
  List<GifItem> _items = const [];
  bool _loading = false;
  String? _error;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    if (widget.client.configured) _run('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _run(String q) async {
    final t = ++_token;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.client.search(q);
      if (!mounted || t != _token) return;
      setState(() {
        _items = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || t != _token) return;
      setState(() {
        _error = e is MediaException ? e.message : 'Could not load stickers.';
        _loading = false;
      });
    }
  }

  void _pick(GifItem g) {
    Navigator.pop(
      context,
      StoryOverlay(
        text: 'sticker',
        dy: 0.45,
        image: g.url,
        still: g.stillUrl,
        aspect: g.aspect,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final withGiphy = widget.client.configured;
    return Column(
      children: [
        if (withGiphy)
          TabBar(
            controller: _tabs,
            tabs: [
              Tab(text: context.tr('Stickers')),
              Tab(text: context.tr('Emoji')),
            ],
          ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              if (withGiphy) _stickers(context),
              _emoji(context),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stickers(BuildContext context) {
    final cols = MediaQuery.sizeOf(context).width > 700 ? 5 : 3;
    Widget body;
    if (_loading && _items.isEmpty) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = Center(child: Text(_error!, textAlign: TextAlign.center));
    } else if (_items.isEmpty) {
      body = Center(child: Text(context.tr('No stickers found.')));
    } else {
      body = GridView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: _items.length,
        itemBuilder: (context, i) {
          final g = _items[i];
          return GestureDetector(
            key: ValueKey('sticker_${g.id}'),
            onTap: () => _pick(g),
            child: Container(
              decoration: BoxDecoration(
                color: context.softFill,
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.all(8),
              child: CachedNetworkImage(
                imageUrl: g.previewUrl,
                fit: BoxFit.contain,
                errorWidget: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          );
        },
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: TextField(
            key: const ValueKey('stickerSearch'),
            controller: _q,
            onChanged: (v) {
              _debounce?.cancel();
              _debounce = Timer(
                const Duration(milliseconds: 400),
                () => _run(v),
              );
            },
            decoration: InputDecoration(
              hintText: context.tr('Search stickers'),
              prefixIcon: const Icon(Icons.search_rounded),
            ),
          ),
        ),
        Expanded(child: body),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            'Powered by GIPHY',
            style: TextStyle(
              color: context.muted,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _emoji(BuildContext context) {
    return GridView.count(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      crossAxisCount: 8,
      children: [
        for (final e in kOverlayEmojis)
          InkWell(
            key: ValueKey('emoji_$e'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => Navigator.pop(
              context,
              StoryOverlay(text: e, dy: 0.45, emoji: true),
            ),
            child: Center(child: Text(e, style: const TextStyle(fontSize: 28))),
          ),
      ],
    );
  }
}

/// Drags, pinches and taps the texts and stickers on a picture of any shape. Positions and
/// sizes are fractions of the picture, so they look the same everywhere.
class OverlayEditLayer extends StatefulWidget {
  const OverlayEditLayer({
    super.key,
    required this.overlays,
    required this.onChanged,
    required this.onTap,
    this.selected,
    this.onBackgroundTap,
  });

  /// The item that is selected (frame and corner handle), if any.
  final int? selected;

  /// Called when the picture is tapped while an item is selected.
  final VoidCallback? onBackgroundTap;

  final List<StoryOverlay> overlays;
  final ValueChanged<List<StoryOverlay>> onChanged;
  final void Function(int index) onTap;

  @override
  State<OverlayEditLayer> createState() => _OverlayEditLayerState();
}

class _OverlayEditLayerState extends State<OverlayEditLayer> {
  double _baseScale = 1;

  /// The selected item: a frame around it and a round handle in the corner. Dragging the
  /// handle makes it bigger or smaller.
  Widget _selectedChip(List<StoryOverlay> list, int i, double w, double h) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: DecoratedBox(
            key: const ValueKey('selectedFrame'),
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 1.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: StoryOverlayChip(overlay: list[i], canvasWidth: w),
            ),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: GestureDetector(
            key: const ValueKey('resizeHandle'),
            behavior: HitTestBehavior.opaque,
            onScaleUpdate: (d) {
              final o = widget.overlays[i];
              final next = [...widget.overlays];
              final factor =
                  1 + (d.focalPointDelta.dx + d.focalPointDelta.dy) / (w * 0.45);
              next[i] = o.copyWith(scale: (o.scale * factor).clamp(0.4, 4.0));
              widget.onChanged(next);
            },
            child: Container(
              width: 28,
              height: 28,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(blurRadius: 6, color: Colors.black38)],
              ),
              child: const Icon(
                Icons.open_in_full_rounded,
                size: 15,
                color: Colors.black87,
              ),
            ),
          ),
        ),
      ],
    );
  }

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
            if (widget.selected != null)
              Positioned.fill(
                child: GestureDetector(
                  key: const ValueKey('overlayBackground'),
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onBackgroundTap,
                ),
              ),
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
                      child: widget.selected == i
                          ? _selectedChip(list, i, w, h)
                          : StoryOverlayChip(overlay: list[i], canvasWidth: w),
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
