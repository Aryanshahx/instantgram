import '../../../core/services/net_priority.dart';
import '../../../shared/widgets/refresh_note.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../core/services/media_prefetch.dart';
import '../../../core/services/hyper_intelligence.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/ig_text_field.dart';
import '../../../shared/widgets/media_view.dart';
import '../../../shared/widgets/post_grid.dart';
import '../../../shared/widgets/user_tile.dart';
import '../../post/data/post_repository.dart';
import '../../profile/data/user_repository.dart';
import '../../../core/services/net_quality.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/navigation/page_cover.dart';
import '../../../core/services/video_cache.dart';

class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

/// Explore:
///  * no search  -> grid of the latest clips (they play muted when visible)
///  * search     -> people + clips (never photo posts)
///  * "#tag"     -> clips with that hashtag
class _ExploreScreenState extends State<ExploreScreen> {
  final _searchCtrl = TextEditingController();
  // one stream for the grid AND search (clips only, never photo posts)
  late Stream<List<Post>> _recentClips = _newStream();
  final ExploreAutoplay _autoplay = ExploreAutoplay();
  List<Post>? _lastClips;
  Timer? _debounce;
  String _query = '';
  List<UserProfile> _people = const [];
  List<Post> _tagClips = const [];
  bool _searching = false;

  bool get _isTag => _query.startsWith('#');

  Stream<List<Post>> _newStream() => PostRepository.instance
      .recent(type: Post.clip, limit: 100)
      .asBroadcastStream();

  /// Swipe down: load the newest clips again (and search again).
  /// v0.13: waits for the server (background downloads pause meanwhile).
  Future<void> _refresh() async {
    final ok = await NetPriority.refresh(
      () => PostRepository.instance.refreshRecent(type: Post.clip, limit: 100),
    );
    if (!mounted) return;
    setState(() => _recentClips = _newStream());
    if (_word.isNotEmpty) _onChanged(_searchCtrl.text);
    if (!ok) refreshFailed(context);
  }

  String get _word => _query.replaceFirst('#', '').trim().toLowerCase();

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _autoplay.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    final q = v.trim();
    setState(() => _query = q);
    _debounce?.cancel();
    if (q.replaceFirst('#', '').isEmpty) {
      setState(() {
        _people = const [];
        _tagClips = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final word = q.replaceFirst('#', '').trim().toLowerCase();
      final isTag = q.startsWith('#');
      try {
        final results = await Future.wait([
          isTag
              ? Future.value(<UserProfile>[])
              : UserRepository.instance.search(word),
          PostRepository.instance.clipsByTag(word),
        ]);
        if (mounted && _query == q) {
          setState(() {
            _people = results[0] as List<UserProfile>;
            _tagClips = results[1] as List<Post>;
            _searching = false;
          });
        }
      } catch (_) {
        if (mounted && _query == q) setState(() => _searching = false);
      }
    });
  }

  /// Clips that match the search (hashtag field, caption or username).
  List<Post> _matchClips(List<Post> recentClips) {
    final w = _word;
    final byId = <String, Post>{for (final p in _tagClips) p.id: p};
    for (final p in recentClips) {
      final caption = p.caption.toLowerCase();
      final match = _isTag
          ? caption.contains('#$w')
          : caption.contains(w) || p.authorUsername.toLowerCase().contains(w);
      if (match) byId[p.id] = p;
    }
    return byId.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Widget _grid(List<Post> posts) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    sliver: SliverMasonryGrid.count(
      crossAxisCount: 2,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childCount: posts.length,
      itemBuilder: (context, i) {
        MediaPrefetch.instance.ahead(posts, i, images: 4, videos: 0);
        return ExploreTile(
          key: ValueKey('explore-${posts[i].id}'),
          post: posts[i],
          autoplay: _autoplay,
          onTap: () => openPost(context, posts, i, source: ViewSource.explore),
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hasQuery = _word.isNotEmpty;
    return SafeArea(
      bottom: false,
      child: StreamBuilder<List<Post>>(
        stream: _recentClips,
        initialData: _lastClips,
        builder: (context, snap) {
          if (snap.hasData) _lastClips = snap.data;
          final header = SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Explore', style: AppTheme.pageTitle),
                  const SizedBox(height: 14),
                  IgTextField(
                    hint: 'Search people, clips or #tags',
                    icon: Icons.search,
                    height: 46,
                    controller: _searchCtrl,
                    textInputAction: TextInputAction.search,
                    onChanged: _onChanged,
                  ),
                ],
              ),
            ),
          );

          final List<Widget> body;
          if (snap.hasError) {
            body = [SliverToBoxAdapter(child: ErrorView(error: snap.error))];
          } else if (!snap.hasData) {
            body = [const SliverToBoxAdapter(child: LoadingView())];
          } else if (!hasQuery) {
            final posts = snap.data!;
            body = posts.isEmpty
                ? [
                    const SliverToBoxAdapter(
                      child: EmptyState(
                        icon: Icons.explore_outlined,
                        title: 'Nothing to explore yet',
                        subtitle: 'New clips will show up here.',
                      ),
                    ),
                  ]
                : [_grid(posts)];
          } else {
            final clips = _matchClips(snap.data!);
            body = [
              if (_people.isNotEmpty) ...[
                const SliverToBoxAdapter(child: _SectionTitle('People')),
                SliverList.builder(
                  itemCount: _people.length,
                  itemBuilder: (context, i) => UserTile(
                    user: _people[i],
                    onTap: () => openProfile(context, _people[i].uid),
                  ),
                ),
              ],
              if (clips.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: _SectionTitle(_isTag ? 'Clips with #$_word' : 'Clips'),
                ),
                _grid(clips),
              ],
              if (_searching)
                const SliverToBoxAdapter(child: LoadingView(padding: 16))
              else if (_people.isEmpty && clips.isEmpty)
                SliverToBoxAdapter(
                  child: EmptyState(
                    icon: Icons.search_off,
                    title: 'Nothing found',
                    subtitle: _isTag
                        ? 'No clips with #$_word yet.'
                        : 'Try another name, word or #tag.',
                  ),
                ),
            ];
          }

          return RefreshIndicator(
            key: const ValueKey('explore-refresh'),
            color: AppColors.lime,
            backgroundColor: AppColors.surface,
            onRefresh: _refresh,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                header,
                ...body,
                const SliverToBoxAdapter(child: SizedBox(height: 110)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
    child: Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
    ),
  );
}

/// Decides which Explore tiles play: the most visible ones (max
/// [maxPlayers] at once, so the phone stays smooth). The others show
/// their cover.
class ExploreAutoplay extends ChangeNotifier {
  ExploreAutoplay({this.maxPlayers = 6, this.minVisible = 0.5});

  final int maxPlayers;
  final double minVisible;
  final Map<String, double> _visible = {};
  Set<String> _active = const {};
  bool _disposed = false;

  bool isActive(String id) => _active.contains(id);
  Set<String> get active => _active;

  void report(String id, double fraction) {
    if (_disposed) return;
    if (fraction <= 0) {
      if (_visible.remove(id) == null) return;
    } else {
      _visible[id] = fraction;
    }
    _recompute();
  }

  /// Tile left the tree (no notify during build/dispose).
  void forget(String id) {
    if (_disposed || _visible.remove(id) == null) return;
    Future<void>.microtask(_recompute);
  }

  void _recompute() {
    if (_disposed) return;
    final list = _visible.entries.where((e) => e.value >= minVisible).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final next = list.take(maxPlayers).map((e) => e.key).toSet();
    if (setEquals(next, _active)) return;
    _active = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class ExploreTile extends StatefulWidget {
  const ExploreTile({
    super.key,
    required this.post,
    required this.onTap,
    required this.autoplay,
  });

  final Post post;
  final VoidCallback onTap;
  final ExploreAutoplay autoplay;

  @override
  State<ExploreTile> createState() => _ExploreTileState();
}

class _ExploreTileState extends State<ExploreTile> {
  @override
  void dispose() {
    widget.autoplay.forget(widget.post.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final first = post.items.isEmpty ? null : post.items.first;
    // v0.18: a blurred clip never plays in the tile
    final video =
        first != null &&
            first.isVideo &&
            !HyperIntelligence.instance.blurs(post)
        ? first
        : null;
    return VisibilityDetector(
      key: ValueKey('explore-vis-${post.id}'),
      onVisibilityChanged: (info) =>
          widget.autoplay.report(post.id, info.visibleFraction),
      child: GestureDetector(
        onTap: widget.onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: AspectRatio(
            aspectRatio: 0.62,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipCover(post: post),
                if (video != null)
                  ListenableBuilder(
                    listenable: widget.autoplay,
                    builder: (context, _) => widget.autoplay.isActive(post.id)
                        ? _TileVideo(item: video)
                        : const SizedBox.shrink(),
                  ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.center,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0x99000000)],
                    ),
                  ),
                ),
                if (post.pinned)
                  const Positioned(
                    left: 10,
                    top: 10,
                    child: Icon(Icons.push_pin, size: 18, color: Colors.white),
                  ),
                Positioned(
                  left: 10,
                  bottom: 9,
                  child: Row(
                    key: const ValueKey('explore-views'),
                    children: [
                      const Icon(
                        Icons.remove_red_eye_outlined,
                        size: 17,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        compactCount(post.viewsCount),
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Muted looping preview of a clip (sound and music stay off in Explore).
class _TileVideo extends StatefulWidget {
  const _TileVideo({required this.item});
  final MediaItem item;

  @override
  State<_TileVideo> createState() => _TileVideoState();
}

class _TileVideoState extends State<_TileVideo> with PageCoverAware {
  // v0.8: paused while a page (moments, a clip…) is open on top
  @override
  void onPageCoverChanged(bool covered) {
    final c = _c;
    if (c == null || !_ready) return;
    covered ? c.pause() : c.play();
  }

  VideoPlayerController? _c;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (kDisableVideoPlayback || widget.item.url.isEmpty) return;
    // small tiles: the small copy is enough (loads much faster);
    // muted preview must never stop other apps' music; disk cache (v0.8)
    final c = VideoCache.instance.controller(
      NetQuality.tileUrl(widget.item),
      mixWithOthers: true,
    );
    _c = c;
    try {
      await c.initialize();
      if (!mounted || _c != c) return;
      await c.setVolume(0);
      await c.setLooping(true);
      final start = widget.item.edits.trimStartMs;
      if (start > 0) await c.seekTo(Duration(milliseconds: start));
      if (!mounted || _c != c) return;
      if (!pageCovered) await c.play();
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      // cover stays visible
    }
  }

  @override
  void dispose() {
    final c = _c;
    _c = null;
    c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || !_ready) return const SizedBox.shrink();
    final size = c.value.size;
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: size.width <= 0 ? 1 : size.width,
        height: size.height <= 0 ? 1 : size.height,
        child: VideoPlayer(c),
      ),
    );
  }
}
