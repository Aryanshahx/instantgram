import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/ig_text_field.dart';
import '../../../shared/widgets/net_image.dart';
import '../../../shared/widgets/post_grid.dart';
import '../../../shared/widgets/user_tile.dart';
import '../../post/data/post_repository.dart';
import '../../profile/data/user_repository.dart';

class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

/// Explore:
///  * no search  -> grid of the latest posts + clips
///  * search     -> people + clips (never photo posts)
///  * "#tag"     -> clips with that hashtag
class _ExploreScreenState extends State<ExploreScreen> {
  final _searchCtrl = TextEditingController();
  final Stream<List<Post>> _recent =
      PostRepository.instance.recent(limit: 90);
  final Stream<List<Post>> _recentClips =
      PostRepository.instance.recent(type: Post.clip, limit: 100);
  Timer? _debounce;
  String _query = '';
  List<UserProfile> _people = const [];
  List<Post> _tagClips = const [];
  bool _searching = false;

  bool get _isTag => _query.startsWith('#');
  String get _word => _query.replaceFirst('#', '').trim().toLowerCase();

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
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
          itemBuilder: (context, i) => _ExploreTile(
            post: posts[i],
            onTap: () => openPost(context, posts, i),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final hasQuery = _word.isNotEmpty;
    return SafeArea(
      bottom: false,
      child: StreamBuilder<List<Post>>(
        stream: hasQuery ? _recentClips : _recent,
        builder: (context, snap) {
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
                        subtitle: 'New posts and clips will show up here.',
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

          return CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              header,
              ...body,
              const SliverToBoxAdapter(child: SizedBox(height: 110)),
            ],
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

class _ExploreTile extends StatelessWidget {
  const _ExploreTile({required this.post, required this.onTap});

  final Post post;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ratio = post.isClip ? 0.62 : post.aspectRatio.clamp(0.56, 1.8);
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: AspectRatio(
          aspectRatio: ratio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (post.isClip) ClipCover(post: post) else NetImage(post.mediaUrl),
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
                  child: Icon(Icons.push_pin, size: 20, color: Colors.white),
                ),
              if (post.isClip)
                const Positioned(
                  right: 10,
                  top: 10,
                  child: Icon(Icons.play_circle_fill,
                      size: 22, color: Colors.white),
                ),
              Positioned(
                left: 10,
                bottom: 10,
                child: Row(
                  children: [
                    const Icon(Icons.favorite, size: 20, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(
                      compactCount(post.likesCount),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
