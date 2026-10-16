import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/models/post.dart';
import '../../../shared/widgets/net_image.dart';
import '../data/highlight_repository.dart';
import '../data/moments_index.dart';
import '../../../shared/widgets/hi_text_check.dart';

/// v0.15: the row of highlights under the profile buttons.
/// Your own row starts with "New" (plus ring) to make a highlight.
class HighlightsRow extends StatefulWidget {
  const HighlightsRow({
    super.key,
    required this.uid,
    required this.isMe,
    this.stream,
    this.onOpen,
    this.onNew,
  });

  final String uid;
  final bool isMe;

  /// Tests: highlights to show (default: Firestore).
  final Stream<List<Highlight>>? stream;

  /// Tests: what a tap does (default: the moment viewer).
  final void Function(Highlight h)? onOpen;

  /// Tests: what "New" does (default: [HighlightEditorScreen]).
  final VoidCallback? onNew;

  @override
  State<HighlightsRow> createState() => _HighlightsRowState();
}

class _HighlightsRowState extends State<HighlightsRow> {
  late Stream<List<Highlight>> _stream =
      widget.stream ?? HighlightRepository.instance.watch(widget.uid);

  @override
  void didUpdateWidget(covariant HighlightsRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid || oldWidget.stream != widget.stream) {
      _stream = widget.stream ?? HighlightRepository.instance.watch(widget.uid);
    }
  }

  void _open(Highlight h) {
    if (widget.onOpen != null) return widget.onOpen!(h);
    openStoryViewer(context, [h.group], 0, recordViews: false, title: h.title);
  }

  void _new() {
    if (widget.onNew != null) return widget.onNew!();
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const HighlightEditorScreen()),
    );
  }

  Future<void> _menu(Highlight h) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                h.title,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            ListTile(
              key: const ValueKey('highlight-edit'),
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit highlight'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              key: const ValueKey('highlight-delete'),
              leading: const Icon(Icons.delete_outline, color: AppColors.like),
              title: const Text(
                'Delete highlight',
                style: TextStyle(color: AppColors.like),
              ),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'edit') {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => HighlightEditorScreen(edit: h)),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete this highlight?'),
        content: const Text('Your moments are not deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('highlight-delete-ok'),
            onPressed: () => Navigator.pop(d, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: AppColors.like),
            ),
          ),
        ],
      ),
    );
    if (ok == true) {
      await HighlightRepository.instance.delete(h).catchError((Object _) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Highlight>>(
      stream: _stream,
      builder: (context, snap) {
        final list = snap.data ?? const <Highlight>[];
        if (!widget.isMe && list.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SizedBox(
            height: 82,
            child: ListView(
              key: const ValueKey('highlights-row'),
              scrollDirection: Axis.horizontal,
              children: [
                if (widget.isMe)
                  _Bubble(
                    key: const ValueKey('highlight-new'),
                    label: 'New',
                    onTap: _new,
                    child: const Icon(Icons.add, size: 26),
                  ),
                for (final h in list)
                  _Bubble(
                    key: ValueKey('highlight-${h.id}'),
                    label: h.title,
                    onTap: () => _open(h),
                    onLongPress: widget.isMe ? () => _menu(h) : null,
                    child: h.coverUrl.isEmpty
                        ? const Icon(Icons.play_arrow_rounded, size: 26)
                        : ClipOval(
                            child: SizedBox.expand(
                              child: NetImage(h.coverUrl, fit: BoxFit.cover),
                            ),
                          ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.label,
    required this.child,
    required this.onTap,
    this.onLongPress,
  });

  final String label;
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 70,
        child: Column(
          children: [
            Container(
              width: 58,
              height: 58,
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF808186), width: 1.5),
              ),
              child: Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF2D3035),
                ),
                child: Center(child: child),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------- editor

/// Make or change a highlight: pick moments (old ones too), a name and a
/// cover photo.
class HighlightEditorScreen extends StatefulWidget {
  const HighlightEditorScreen({
    super.key,
    this.edit,
    this.loadMoments,
    this.onSave,
  });

  final Highlight? edit;

  /// Tests: your moments (default: Firestore).
  final Future<List<Story>> Function()? loadMoments;

  /// Tests: saving (default: Firestore).
  final Future<void> Function(String title, List<Story> items, String cover)?
  onSave;

  @override
  State<HighlightEditorScreen> createState() => _HighlightEditorScreenState();
}

class _HighlightEditorScreenState extends State<HighlightEditorScreen> {
  late final _title = TextEditingController(text: widget.edit?.title ?? '');
  late final List<String> _picked = [...?widget.edit?.storyIds];
  late String _cover = widget.edit?.coverUrl ?? '';
  List<Story>? _moments;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list =
          await (widget.loadMoments ??
              HighlightRepository.instance.myMoments)();
      // moments that were deleted but are still in this highlight
      final extra = [
        for (final s in widget.edit?.items ?? const <Story>[])
          if (!list.any((m) => m.id == s.id)) s,
      ];
      if (!mounted) return;
      setState(() {
        _moments = [...list, ...extra]
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load your moments');
    }
  }

  List<Story> get _selected {
    final all = _moments ?? const <Story>[];
    return [for (final id in _picked) ...all.where((s) => s.id == id).take(1)];
  }

  void _toggle(Story s) {
    setState(() {
      if (_picked.contains(s.id)) {
        _picked.remove(s.id);
        if (_cover == s.mediaUrl) _cover = '';
      } else if (_picked.length < Highlight.maxItems) {
        _picked.add(s.id);
      }
    });
  }

  Future<void> _save() async {
    final items = _selected;
    if (items.isEmpty || _saving) return;
    // v0.18 Hyper Intelligence: no strong abuse in the name
    if (!await hiTextOk(context, [_title.text]) || !mounted) return;
    setState(() => _saving = true);
    final cover = Highlight.coverOf(items, preferred: _cover);
    try {
      if (widget.onSave != null) {
        await widget.onSave!(_title.text, items, cover);
      } else if (widget.edit != null) {
        await HighlightRepository.instance.update(
          widget.edit!,
          _title.text,
          items,
          cover: cover,
        );
      } else {
        await HighlightRepository.instance.create(
          _title.text,
          items,
          cover: cover,
        );
      }
      if (mounted) Navigator.of(context).maybePop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save. Try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final photos = [
      for (final s in selected)
        if (!s.isVideo) s,
    ];
    final cover = Highlight.coverOf(selected, preferred: _cover);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.edit == null ? 'New highlight' : 'Edit highlight'),
        actions: [
          TextButton(
            key: const ValueKey('highlight-save'),
            onPressed: selected.isEmpty || _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    'Save',
                    style: TextStyle(
                      color: selected.isEmpty
                          ? AppColors.textSecondary
                          : AppColors.lime,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              key: const ValueKey('highlight-name'),
              controller: _title,
              maxLength: Highlight.maxTitle,
              decoration: const InputDecoration(
                hintText: 'Highlight name',
                isDense: true,
                counterText: '',
              ),
            ),
          ),
          if (photos.isNotEmpty)
            SizedBox(
              height: 56,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  const Center(
                    child: Text(
                      'Cover  ',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                  for (final s in photos)
                    GestureDetector(
                      key: ValueKey('cover-${s.id}'),
                      onTap: () => setState(() => _cover = s.mediaUrl),
                      child: Container(
                        width: 46,
                        height: 46,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: cover == s.mediaUrl
                                ? AppColors.lime
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        padding: const EdgeInsets.all(2),
                        child: ClipOval(
                          child: NetImage(s.mediaUrl, fit: BoxFit.cover),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            child: Row(
              children: [
                Text(
                  selected.isEmpty
                      ? 'Pick moments'
                      : '${selected.length} selected',
                  key: const ValueKey('highlight-count'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          Expanded(child: _grid()),
        ],
      ),
    );
  }

  Widget _grid() {
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      );
    }
    final list = _moments;
    if (list == null) return const Center(child: CircularProgressIndicator());
    if (list.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(30),
          child: Text(
            'No moments yet.\nShare a moment first, then keep it here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 20),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        childAspectRatio: 9 / 16,
      ),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final s = list[i];
        final n = _picked.indexOf(s.id);
        return GestureDetector(
          key: ValueKey('pick-${s.id}'),
          onTap: () => _toggle(s),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (s.isVideo)
                const ColoredBox(
                  color: Color(0xFF1D2029),
                  child: Icon(Icons.play_circle_outline, size: 34),
                )
              else
                NetImage(s.mediaUrl, fit: BoxFit.cover),
              if (n >= 0) Container(color: Colors.black38),
              Positioned(
                left: 6,
                bottom: 6,
                child: Text(
                  _date(s.createdAt),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(blurRadius: 4)],
                  ),
                ),
              ),
              Positioned(
                right: 6,
                top: 6,
                child: Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: n >= 0 ? AppColors.lime : Colors.black26,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: n >= 0
                      ? Text(
                          '${n + 1}',
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 11,
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
    );
  }

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _date(DateTime d) => '${d.day} ${_months[d.month - 1]}';
}
