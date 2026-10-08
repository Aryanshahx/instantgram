import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../core/media_url.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../models/highlight.dart';
import '../models/story.dart';
import '../screens/story/story_viewer.dart';
import '../services/highlight_service.dart';
import '../services/story_service.dart';

/// The round picture of a highlight (or of a moment in the picker).
class HighlightCircle extends StatelessWidget {
  const HighlightCircle({
    super.key,
    required this.coverRef,
    this.size = 64,
    this.icon,
  });

  final String coverRef;
  final double size;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final url = resolveMediaUrl(coverRef);
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: context.muted.withValues(alpha: 0.5),
          width: 1.5,
        ),
      ),
      child: ClipOval(
        child: ColoredBox(
          color: context.muted.withValues(alpha: 0.15),
          child: icon != null || url.isEmpty
              ? Icon(icon ?? Icons.auto_stories_rounded, size: size * 0.4)
              : Image(
                  image: CachedNetworkImageProvider(url, maxWidth: 240),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      Icon(Icons.auto_stories_rounded, size: size * 0.4),
                ),
        ),
      ),
    );
  }
}

/// Highlights under a profile's header. Mine starts with "New"; long-press one of mine to
/// rename or delete it. Hidden on other people's profiles when they have none.
class HighlightsRow extends StatefulWidget {
  const HighlightsRow({
    super.key,
    required this.uid,
    required this.username,
    required this.photoUrl,
    required this.isMe,
  });

  final String uid;
  final String username;
  final String photoUrl;
  final bool isMe;

  @override
  State<HighlightsRow> createState() => _HighlightsRowState();
}

class _HighlightsRowState extends State<HighlightsRow> {
  List<Highlight>? _list;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(HighlightsRow old) {
    super.didUpdateWidget(old);
    if (old.uid != widget.uid) {
      _list = null;
      _load();
    }
  }

  Future<void> _load({bool fresh = false}) async {
    try {
      final s = HighlightService.instance;
      final l = widget.isMe
          ? await s.mine(fresh: fresh)
          : await s.of(widget.uid);
      if (mounted) setState(() => _list = l);
    } catch (_) {
      if (mounted) setState(() => _list = const []);
    }
  }

  Future<void> _open(Highlight h) async {
    if (h.items.isEmpty) {
      if (widget.isMe) {
        showToast(
          context,
          'Empty. Share a moment to it, or add one from your moment.',
        );
      }
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => StoryViewer(
          groups: [h.toGroup(widget.uid, widget.username, widget.photoUrl)],
          initialIndex: 0,
          highlight: h,
        ),
      ),
    );
    _load();
  }

  Future<void> _new() async {
    final h = await createHighlight(context);
    if (h != null) _load();
  }

  Future<void> _manage(Highlight h) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('hlRename'),
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              key: const ValueKey('hlDelete'),
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: AppTheme.coral,
              ),
              title: const Text(
                'Delete highlight',
                style: TextStyle(color: AppTheme.coral),
              ),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    try {
      if (choice == 'rename') {
        final t = await askHighlightTitle(context, start: h.title);
        if (t == null) return;
        await HighlightService.instance.rename(h, t);
      } else {
        final ok = await confirm(
          context,
          title: 'Delete "${h.title}"?',
          message: 'The moments in it are not deleted.',
          confirmLabel: 'Delete',
          destructive: true,
        );
        if (!ok) return;
        await HighlightService.instance.delete(h);
      }
      _load();
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    }
  }

  Widget _item({
    required Key key,
    required Widget circle,
    required String label,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6),
    child: GestureDetector(
      key: key,
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: 72,
        child: Column(
          children: [
            circle,
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final list = _list;
    if (list == null) return const SizedBox(height: 4);
    if (list.isEmpty && !widget.isMe) return const SizedBox.shrink();
    return SizedBox(
      height: 98,
      child: ListView(
        key: const ValueKey('highlightsRow'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        children: [
          if (widget.isMe)
            _item(
              key: const ValueKey('hlNew'),
              circle: const HighlightCircle(
                coverRef: '',
                icon: Icons.add_rounded,
              ),
              label: 'New',
              onTap: _new,
            ),
          for (final h in list)
            _item(
              key: ValueKey('hl_${h.id}'),
              circle: HighlightCircle(coverRef: h.cover),
              label: h.title,
              onTap: () => _open(h),
              onLongPress: widget.isMe ? () => _manage(h) : null,
            ),
        ],
      ),
    );
  }
}

/// Asks for a highlight name. Null = cancelled.
Future<String?> askHighlightTitle(BuildContext context, {String start = ''}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _TitleDialog(start: start),
    );

class _TitleDialog extends StatefulWidget {
  const _TitleDialog({required this.start});
  final String start;

  @override
  State<_TitleDialog> createState() => _TitleDialogState();
}

class _TitleDialogState extends State<_TitleDialog> {
  late final TextEditingController _c = TextEditingController(
    text: widget.start,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.start.isEmpty ? 'New highlight' : 'Rename highlight'),
    content: TextField(
      key: const ValueKey('hlTitle'),
      controller: _c,
      autofocus: true,
      maxLength: 20,
      textCapitalization: TextCapitalization.sentences,
      decoration: const InputDecoration(hintText: 'Travel, Friends, 2026...'),
      onSubmitted: (v) => Navigator.pop(context, v),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('hlTitleOk'),
        onPressed: () => Navigator.pop(context, _c.text),
        child: const Text('OK'),
      ),
    ],
  );
}

/// "New" on the profile: a name, then (optionally) moments from the archive.
/// Returns the new highlight, or null.
Future<Highlight?> createHighlight(BuildContext context) async {
  final title = await askHighlightTitle(context);
  if (title == null || !context.mounted) return null;
  return Navigator.of(context).push<Highlight>(
    MaterialPageRoute(builder: (_) => NewHighlightScreen(title: title)),
  );
}

/// Tests replace the archive (my moments, also expired).
Future<List<Story>> Function()? debugArchive;

/// Pick moments for a new highlight. Creating it empty is fine: moments can be shared
/// straight to it later ("Only a highlight" when sharing).
class NewHighlightScreen extends StatefulWidget {
  const NewHighlightScreen({super.key, required this.title});
  final String title;

  @override
  State<NewHighlightScreen> createState() => _NewHighlightScreenState();
}

class _NewHighlightScreenState extends State<NewHighlightScreen> {
  List<Story>? _all;
  final List<String> _picked = [];
  bool _saving = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await (debugArchive?.call() ?? StoryService.instance.archive());
      if (mounted) setState(() => _all = l);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _create() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final s = HighlightService.instance;
      final byId = {for (final x in _all ?? const <Story>[]) x.id: x};
      // oldest first inside the highlight, like the moments were shared
      final chosen = [for (final id in _picked) ?byId[id]]
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      var h = await s.create(widget.title);
      for (final st in chosen) {
        h = await s.addStory(h, st);
      }
      if (mounted) Navigator.of(context).pop(h);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showToast(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = _all;
    return Scaffold(
      appBar: AppBar(
        title: Text(Highlight.cleanTitle(widget.title)),
        actions: [
          TextButton(
            key: const ValueKey('hlCreate'),
            onPressed: _saving ? null : _create,
            child: Text(
              _picked.isEmpty ? 'Create empty' : 'Create (${_picked.length})',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      body: _error != null
          ? const Center(child: Text('Could not load your moments.'))
          : all == null
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : all.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No moments yet. Create it empty and share moments straight to it.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.muted),
                ),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(2),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 140,
                childAspectRatio: 9 / 16,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemCount: all.length,
              itemBuilder: (_, i) {
                final st = all[i];
                final n = _picked.indexOf(st.id);
                final url = st.coverUrl;
                return GestureDetector(
                  key: ValueKey('arch_${st.id}'),
                  onTap: () => setState(
                    () => n >= 0 ? _picked.remove(st.id) : _picked.add(st.id),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: Colors.black,
                        child: url.isEmpty
                            ? const Icon(
                                Icons.image_outlined,
                                color: Colors.white38,
                              )
                            : Image(
                                image: CachedNetworkImageProvider(
                                  url,
                                  maxWidth: 300,
                                ),
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    const SizedBox.shrink(),
                              ),
                      ),
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: Text(
                          '${st.createdAt.day}/${st.createdAt.month}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            shadows: [Shadow(blurRadius: 6)],
                          ),
                        ),
                      ),
                      Positioned(
                        right: 6,
                        top: 6,
                        child: CircleAvatar(
                          radius: 12,
                          backgroundColor: n >= 0
                              ? AppTheme.volt
                              : Colors.black45,
                          child: n >= 0
                              ? Text(
                                  '${n + 1}',
                                  style: const TextStyle(
                                    color: AppTheme.ink,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

/// From one of my moments: pick a highlight (or make a new one) to put it in.
Future<Highlight?> pickHighlight(BuildContext context) =>
    showModalBottomSheet<Highlight>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _PickHighlightSheet(),
    );

class _PickHighlightSheet extends StatefulWidget {
  const _PickHighlightSheet();

  @override
  State<_PickHighlightSheet> createState() => _PickHighlightSheetState();
}

class _PickHighlightSheetState extends State<_PickHighlightSheet> {
  List<Highlight>? _list;

  @override
  void initState() {
    super.initState();
    HighlightService.instance.mine().then(
      (l) {
        if (mounted) setState(() => _list = l);
      },
      onError: (_) {
        if (mounted) setState(() => _list = const []);
      },
    );
  }

  Future<void> _new() async {
    final t = await askHighlightTitle(context);
    if (t == null || !mounted) return;
    try {
      final h = await HighlightService.instance.create(t);
      if (mounted) Navigator.of(context).pop(h);
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Text(
              'Add to highlight',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
            ),
          ),
          SizedBox(
            height: 104,
            child: list == null
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    children: [
                      _choice(
                        const ValueKey('pickHlNew'),
                        const HighlightCircle(
                          coverRef: '',
                          icon: Icons.add_rounded,
                        ),
                        'New',
                        _new,
                      ),
                      for (final h in list)
                        _choice(
                          ValueKey('pickHl_${h.id}'),
                          HighlightCircle(coverRef: h.cover),
                          h.title,
                          () => Navigator.of(context).pop(h),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _choice(Key key, Widget circle, String label, VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: GestureDetector(
          key: key,
          onTap: onTap,
          child: SizedBox(
            width: 72,
            child: Column(
              children: [
                circle,
                const SizedBox(height: 4),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
      );
}
