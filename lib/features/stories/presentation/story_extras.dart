import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/services/video_cache.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/net_image.dart';
import '../../../shared/widgets/verified_badge.dart';
import '../../editor/filters.dart';
import '../data/story_views.dart';

// ------------------------------------------------------------ "Seen by" bar

/// v0.15: bottom bar on your own moment: people + rewatches.
class SeenByBar extends StatelessWidget {
  const SeenByBar({super.key, required this.views, required this.onTap});

  final Stream<List<StoryView>> views;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<StoryView>>(
      stream: views,
      builder: (context, snap) {
        final (people, re) = StoryInsights.totals(snap.data ?? const []);
        final likes = StoryInsights.likes(snap.data ?? const []);
        return GestureDetector(
          key: const ValueKey('story-seen-by'),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: Colors.black45,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.visibility_outlined, size: 18),
                const SizedBox(width: 6),
                Text(
                  '$people',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (re > 0) ...[
                  const SizedBox(width: 12),
                  const Icon(Icons.replay_rounded, size: 17),
                  const SizedBox(width: 4),
                  Text(
                    '$re',
                    key: const ValueKey('story-rewatches'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
                // v0.16: likes
                if (likes > 0) ...[
                  const SizedBox(width: 12),
                  const Icon(Icons.favorite, size: 17, color: AppColors.like),
                  const SizedBox(width: 4),
                  Text(
                    '$likes',
                    key: const ValueKey('story-likes'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
                const SizedBox(width: 6),
                const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Opens the viewer list (search + rewatches).
Future<void> showStoryViewers(
  BuildContext context,
  Stream<List<StoryView>> views,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.75,
      child: StoryViewersSheet(views: views),
    ),
  );
}

class StoryViewersSheet extends StatefulWidget {
  const StoryViewersSheet({super.key, required this.views});

  final Stream<List<StoryView>> views;

  @override
  State<StoryViewersSheet> createState() => _StoryViewersSheetState();
}

class _StoryViewersSheetState extends State<StoryViewersSheet> {
  final _q = TextEditingController();
  bool _most = false;
  bool _likedOnly = false;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Widget _stat(
    IconData icon,
    Color? color,
    String text,
    String key, {
    bool bold = false,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: bold ? 20 : 17, color: color),
      const SizedBox(width: 5),
      Text(
        text,
        key: ValueKey(key),
        style: bold
            ? const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)
            : const TextStyle(color: AppColors.textSecondary),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<StoryView>>(
      stream: widget.views,
      builder: (context, snap) {
        final all = snap.data ?? const <StoryView>[];
        final (people, re) = StoryInsights.totals(all);
        final likes = StoryInsights.likes(all);
        final list = StoryInsights.sorted(
          StoryInsights.search(
            _likedOnly ? all.where((v) => v.liked).toList() : all,
            _q.text,
          ),
          mostWatched: _most,
        );
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                // v0.16: wraps on small phones (viewers, rewatches, likes)
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 14,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _stat(
                        Icons.visibility_outlined,
                        null,
                        people == 1 ? '1 viewer' : '$people viewers',
                        'viewers-total',
                        bold: true,
                      ),
                      _stat(
                        Icons.replay_rounded,
                        null,
                        re == 1 ? '1 rewatch' : '$re rewatches',
                        'viewers-rewatches',
                      ),
                      _stat(
                        Icons.favorite,
                        AppColors.like,
                        likes == 1 ? '1 like' : '$likes likes',
                        'viewers-likes',
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 40,
                        child: TextField(
                          key: const ValueKey('viewers-search'),
                          controller: _q,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: 'Search viewers',
                            isDense: true,
                            prefixIcon: const Icon(Icons.search, size: 20),
                            filled: true,
                            fillColor: AppColors.surfaceHigh,
                            contentPadding: EdgeInsets.zero,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(20),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      key: const ValueKey('viewers-sort'),
                      label: const Text('Most watched'),
                      selected: _most,
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      onSelected: (v) => setState(() => _most = v),
                    ),
                    const SizedBox(width: 6),
                    // v0.16: only people who liked it
                    FilterChip(
                      key: const ValueKey('viewers-liked'),
                      label: const Icon(
                        Icons.favorite,
                        size: 16,
                        color: AppColors.like,
                      ),
                      selected: _likedOnly,
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      onSelected: (v) => setState(() => _likedOnly = v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: !snap.hasData
                    ? const Center(child: CircularProgressIndicator())
                    : list.isEmpty
                    ? Center(
                        child: Text(
                          all.isEmpty
                              ? 'No viewers yet'
                              : _likedOnly && likes == 0
                              ? 'No likes yet'
                              : 'No one found',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (context, i) => _ViewerTile(list[i]),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ViewerTile extends StatelessWidget {
  const _ViewerTile(this.v);
  final StoryView v;

  @override
  Widget build(BuildContext context) {
    final when = v.lastAt == null ? '' : ' · ${timeAgo(v.lastAt!)}';
    return ListTile(
      key: ValueKey('viewer-${v.uid}'),
      dense: true,
      leading: Avatar(url: v.photoUrl, name: v.username, size: 38),
      title: NameBadge(
        v.username,
        uid: v.uid,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${StoryInsights.watchedLabel(v.count)}$when',
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
      ),
      trailing: v.rewatches > 0 || v.liked
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (v.liked)
                  Icon(
                    Icons.favorite,
                    key: ValueKey('viewer-liked-${v.uid}'),
                    size: 18,
                    color: AppColors.like,
                  ),
                if (v.liked && v.rewatches > 0) const SizedBox(width: 8),
                if (v.rewatches > 0) _rewatchBadge(),
              ],
            )
          : null,
      onTap: () => openProfile(context, v.uid),
    );
  }

  Widget _rewatchBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.lime.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.replay_rounded, size: 14, color: AppColors.lime),
          const SizedBox(width: 3),
          Text(
            '${v.rewatches}',
            style: const TextStyle(
              color: AppColors.lime,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- preview

/// v0.15: long-press a moment ring = a small preview. It does NOT count as a
/// view and does not mark the moment as seen.
Future<void> showStoryPreview(
  BuildContext context,
  StoryGroup group, {
  required VoidCallback onOpen,
  int index = 0,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (d) => StoryPreviewCard(
      group: group,
      index: index,
      onOpen: () {
        Navigator.pop(d);
        onOpen();
      },
    ),
  );
}

class StoryPreviewCard extends StatefulWidget {
  const StoryPreviewCard({
    super.key,
    required this.group,
    required this.onOpen,
    this.index = 0,
  });

  final StoryGroup group;
  final int index;
  final VoidCallback onOpen;

  @override
  State<StoryPreviewCard> createState() => _StoryPreviewCardState();
}

class _StoryPreviewCardState extends State<StoryPreviewCard> {
  late int _i = widget.index.clamp(0, widget.group.stories.length - 1);
  VideoPlayerController? _video;
  bool _ready = false;

  Story get _story => widget.group.stories[_i];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final old = _video;
    _video = null;
    _ready = false;
    old?.dispose();
    final st = _story;
    if (!st.isVideo || NetImage.disableCache) return;
    final c = VideoCache.instance.controller(st.mediaUrl);
    _video = c;
    try {
      await c.initialize();
      if (!mounted || _video != c) return;
      await c.setVolume(0); // preview is always muted
      await c.setLooping(true);
      final start = st.edits.trimStartMs;
      if (start > 0) await c.seekTo(Duration(milliseconds: start));
      c.play();
      setState(() => _ready = true);
    } catch (_) {
      // stays on the loading look
    }
  }

  void _step(int d) {
    final n = _i + d;
    if (n < 0 || n >= widget.group.stories.length) return;
    setState(() => _i = n);
    _load();
  }

  Widget _media() {
    final st = _story;
    if (!st.isVideo) return NetImage(st.mediaUrl, fit: BoxFit.cover);
    final c = _video;
    if (c == null || !_ready) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Icon(
            Icons.play_circle_outline,
            size: 44,
            color: Colors.white54,
          ),
        ),
      );
    }
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: c.value.size.width,
        height: c.value.size.height,
        child: applyMatrix(st.edits.filter, VideoPlayer(c)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final size = MediaQuery.of(context).size;
    final w = (size.width * 0.72).clamp(200.0, 360.0);
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              key: const ValueKey('story-preview'),
              onTapUp: (d) => d.localPosition.dx < w / 3 ? _step(-1) : _step(1),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: SizedBox(
                  width: w,
                  height: w * 16 / 9 > size.height * 0.62
                      ? size.height * 0.62
                      : w * 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _media(),
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(10, 8, 10, 14),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.black54, Colors.transparent],
                            ),
                          ),
                          child: Column(
                            children: [
                              if (g.stories.length > 1)
                                Row(
                                  children: [
                                    for (var i = 0; i < g.stories.length; i++)
                                      Expanded(
                                        child: Container(
                                          height: 2.5,
                                          margin: const EdgeInsets.symmetric(
                                            horizontal: 1.5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: i <= _i
                                                ? Colors.white
                                                : Colors.white30,
                                            borderRadius: BorderRadius.circular(
                                              2,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Avatar(
                                    url: g.photoUrl,
                                    name: g.username,
                                    size: 28,
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: NameBadge(
                                      g.username,
                                      uid: g.authorId,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    timeAgo(_story.createdAt),
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.visibility_off_outlined,
                  size: 15,
                  color: Colors.white60,
                ),
                SizedBox(width: 6),
                Text(
                  "Preview · they won't see you",
                  style: TextStyle(color: Colors.white60, fontSize: 12.5),
                ),
              ],
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const ValueKey('story-preview-open'),
              onPressed: widget.onOpen,
              icon: const Icon(Icons.open_in_full_rounded, size: 18),
              label: const Text('Open moment'),
            ),
          ],
        ),
      ),
    );
  }
}
