import 'package:flutter/material.dart';

import '../../../shared/models/post.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../feed/presentation/widgets/post_card.dart';
import '../data/post_repository.dart';

class PostDetailScreen extends StatelessWidget {
  const PostDetailScreen({
    super.key,
    required this.postId,
    this.source = ViewSource.other,
  });
  final String postId;

  /// Where it was opened from (for Analytics).
  final String source;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Post')),
      body: StreamBuilder<Post?>(
        stream: PostRepository.instance.watch(postId),
        builder: (context, snap) {
          if (snap.hasError) return ErrorView(error: snap.error);
          if (snap.connectionState == ConnectionState.waiting) {
            return const LoadingView(kind: SkeletonKind.post, count: 1);
          }
          final post = snap.data;
          if (post == null) {
            return const Center(
              child: EmptyState(
                icon: Icons.hide_image_outlined,
                title: 'Post not available',
                subtitle: 'It may have been deleted.',
              ),
            );
          }
          return ListView(
            children: [
              PostCard(
                post: post,
                source: source,
                onDeleted: () => Navigator.of(context).maybePop(),
              ),
            ],
          );
        },
      ),
    );
  }
}
