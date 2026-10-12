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

class _ExploreScreenState extends State<ExploreScreen> {
  final _searchCtrl = TextEditingController();
  final Stream<List<Post>> _recent =
      PostRepository.instance.recent(limit: 90);
  Timer? _debounce;
  String _query = '';
  List<UserProfile> _people = const [];
  bool _searching = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() => _query = v.trim());
    _debounce?.cancel();
    final q = v.trim();
    if (q.isEmpty || q.startsWith('#')) {
      setState(() {
        _people = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final res = await UserRepository.instance.search(q);
        if (mounted && _query == q) {
          setState(() {
            _people = res;
            _searching = false;
          });
        }
      } catch (_) {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  List<Post> _filter(List<Post> posts) {
    final q = _query.toLowerCase().replaceFirst('#', '');
    if (q.isEmpty) return posts;
    return posts
        .where((p) =>
            p.caption.toLowerCase().contains(q) ||
            p.authorUsername.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: StreamBuilder<List<Post>>(
        stream: _recent,
        builder: (context, snap) {
          final posts = _filter(snap.data ?? const []);
          final hasQuery = _query.isNotEmpty;
          return CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Explore', style: AppTheme.screenTitle),
                      const SizedBox(height: 22),
                      IgTextField(
                        hint: 'Search people, clips or #tags',
                        icon: Icons.search,
                        controller: _searchCtrl,
                        textInputAction: TextInputAction.search,
                        onChanged: _onChanged,
                      ),
                    ],
                  ),
                ),
              ),
              if (hasQuery && _searching)
                const SliverToBoxAdapter(child: LoadingView(padding: 16)),
              if (hasQuery && _people.isNotEmpty) ...[
                const SliverToBoxAdapter(child: _SectionTitle('People')),
                SliverList.builder(
                  itemCount: _people.length,
                  itemBuilder: (context, i) => UserTile(
                    user: _people[i],
                    onTap: () => openProfile(context, _people[i].uid),
                  ),
                ),
                if (posts.isNotEmpty)
                  const SliverToBoxAdapter(child: _SectionTitle('Posts')),
              ],
              if (snap.hasError)
                SliverToBoxAdapter(child: ErrorView(error: snap.error))
              else if (!snap.hasData)
                const SliverToBoxAdapter(child: LoadingView())
              else if (posts.isEmpty && !(hasQuery && (_people.isNotEmpty || _searching)))
                SliverToBoxAdapter(
                  child: EmptyState(
                    icon: hasQuery ? Icons.search_off : Icons.explore_outlined,
                    title: hasQuery ? 'Nothing found' : 'Nothing to explore yet',
                    subtitle: hasQuery
                        ? 'Try another username or word.'
                        : 'New posts and clips will show up here.',
                  ),
                )
              else
                SliverPadding(
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
                ),
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
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
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
