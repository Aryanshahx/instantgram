import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/data/mock_data.dart';
import '../../../shared/models/post.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/ig_text_field.dart';
import '../../../shared/widgets/net_image.dart';
import '../../reels/presentation/clips_screen.dart';

class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Post> get _results {
    final q = _query.trim().toLowerCase().replaceFirst('#', '');
    if (q.isEmpty) return MockData.explore;
    return MockData.explore.where((p) {
      return p.username.toLowerCase().contains(q) ||
          p.caption.toLowerCase().contains(q) ||
          p.tags.any((t) => t.toLowerCase().contains(q));
    }).toList();
  }

  void _setQuery(String q) {
    _searchCtrl.text = q;
    _searchCtrl.selection = TextSelection.collapsed(offset: q.length);
    setState(() => _query = q);
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
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
                    onChanged: (v) => setState(() => _query = v),
                  ),
                  const SizedBox(height: 18),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final tag in MockData.trendingTags)
                          Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: _TagChip(
                              tag: tag,
                              selected: _query == '#$tag',
                              onTap: () =>
                                  _setQuery(_query == '#$tag' ? '' : '#$tag'),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
          if (results.isEmpty)
            const SliverToBoxAdapter(
              child: EmptyState(
                icon: Icons.search_off,
                title: 'Nothing found',
                subtitle: 'Try another name or #tag.',
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              sliver: SliverMasonryGrid.count(
                crossAxisCount: 2,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childCount: results.length,
                itemBuilder: (context, i) => _ExploreTile(post: results[i]),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 110)),
        ],
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.tag,
    required this.selected,
    required this.onTap,
  });

  final String tag;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? AppColors.lime : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppColors.lime : const Color(0xFF34392B),
            width: 1.2,
          ),
        ),
        child: Text(
          '#$tag',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: selected ? Colors.black : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _ExploreTile extends StatelessWidget {
  const _ExploreTile({required this.post});

  final Post post;

  @override
  Widget build(BuildContext context) {
    // Keep tiles between square and tall portrait like the design.
    final ratio = post.aspectRatio.clamp(0.56, 1.8);
    return GestureDetector(
      onTap: () {
        if (post.isVideo) {
          Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const ClipsScreen()));
        }
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: AspectRatio(
          aspectRatio: ratio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (post.imageUrl.isEmpty)
                Container(
                  color: const Color(0xFF2E2A5C),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.movie_creation,
                    size: 52,
                    color: Colors.white.withValues(alpha: 0.25),
                  ),
                )
              else
                NetImage(post.imageUrl),
              // bottom shade for readability
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
              if (post.isVideo)
                const Positioned(
                  right: 10,
                  top: 10,
                  child: Icon(
                    Icons.play_circle_fill,
                    size: 22,
                    color: Colors.white,
                  ),
                ),
              Positioned(
                left: 10,
                bottom: 10,
                child: Row(
                  children: [
                    const Icon(Icons.favorite, size: 20, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(
                      compactCount(post.likes),
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
