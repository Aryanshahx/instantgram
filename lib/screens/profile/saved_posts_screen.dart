import 'package:flutter/material.dart';

import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../models/post.dart';
import '../../services/post_service.dart';
import '../../widgets/post_grid.dart';
import '../../widgets/state_views.dart';

/// Posts and clips the current user bookmarked (private).
class SavedPostsScreen extends StatefulWidget {
  const SavedPostsScreen({super.key});

  @override
  State<SavedPostsScreen> createState() => _SavedPostsScreenState();
}

class _SavedPostsScreenState extends State<SavedPostsScreen> {
  late Future<List<Post>> _future = PostService.instance.savedPosts();

  void _reload() => setState(() => _future = PostService.instance.savedPosts());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Saved')),
      body: ContentWidth(
        maxWidth: 860,
        child: FutureBuilder<List<Post>>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) {
              return ErrorState(error: snap.error!, onRetry: _reload);
            }
            if (!snap.hasData) return const CenteredLoader();
            final posts = snap.data!;
            if (posts.isEmpty) {
              return const EmptyState(
                icon: Icons.bookmark_border_rounded,
                title: 'Nothing saved yet',
                subtitle: 'Tap the bookmark on a clip to keep it here.',
              );
            }
            return RefreshIndicator(
              onRefresh: () async {
                _reload();
                await _future;
              },
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  PostGridSliver(posts: posts),
                  const SliverToBoxAdapter(child: SizedBox(height: kNavSpace)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
