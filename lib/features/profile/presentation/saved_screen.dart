import 'package:flutter/material.dart';

import '../../../shared/models/post.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/post_grid.dart';
import '../../post/data/post_repository.dart';

class SavedScreen extends StatefulWidget {
  const SavedScreen({super.key});

  @override
  State<SavedScreen> createState() => _SavedScreenState();
}

class _SavedScreenState extends State<SavedScreen> {
  final Stream<List<String>> _ids = PostRepository.instance.savedIds();
  String _key = '';
  Future<List<Post>>? _future;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Saved')),
      body: StreamBuilder<List<String>>(
        stream: _ids,
        builder: (context, snap) {
          if (snap.hasError) return ErrorView(error: snap.error);
          if (!snap.hasData) return const LoadingView(kind: SkeletonKind.grid);
          final key = snap.data!.join(',');
          if (key != _key || _future == null) {
            _key = key;
            _future = PostRepository.instance.byIds(snap.data!);
          }
          return FutureBuilder<List<Post>>(
            future: _future,
            builder: (context, f) {
              if (f.hasError) return ErrorView(error: f.error);
              if (!f.hasData) return const LoadingView(kind: SkeletonKind.grid);
              final posts = f.data!;
              return PostGrid(
                posts: posts,
                onTap: (i) =>
                    openPost(context, posts, i, source: ViewSource.other),
                emptyIcon: Icons.bookmark_border,
                emptyTitle: 'Nothing saved yet',
                emptySubtitle: 'Tap the bookmark on a post to save it.',
              );
            },
          );
        },
      ),
    );
  }
}
