import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/models/post.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/net_image.dart';
import '../../profile/data/user_repository.dart';
import '../data/post_repository.dart';

/// What to answer a comment with (v0.9).
enum ReplyWith { mine, newClip, newPost }

/// "Reply with a clip or post": pick one of yours, or make a new one.
Future<ReplyWith?> showReplyWithSheet(BuildContext context, {String? to}) =>
    showModalBottomSheet<ReplyWith>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  to == null ? 'Reply with a clip or post' : 'Reply to @$to',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              ListTile(
                key: const ValueKey('reply-with-mine'),
                leading: const Icon(Icons.grid_view_rounded),
                title: const Text('Your clips and posts'),
                onTap: () => Navigator.pop(ctx, ReplyWith.mine),
              ),
              ListTile(
                key: const ValueKey('reply-with-new-clip'),
                leading: const Icon(Icons.videocam_outlined),
                title: const Text('New clip'),
                onTap: () => Navigator.pop(ctx, ReplyWith.newClip),
              ),
              ListTile(
                key: const ValueKey('reply-with-new-post'),
                leading: const Icon(Icons.add_photo_alternate_outlined),
                title: const Text('New post'),
                onTap: () => Navigator.pop(ctx, ReplyWith.newPost),
              ),
            ],
          ),
        ),
      ),
    );

/// Grid of your clips and posts; tap = choose it.
Future<Post?> showMyPostPicker(BuildContext context) =>
    showModalBottomSheet<Post>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const MyPostPicker(),
    );

class MyPostPicker extends StatefulWidget {
  const MyPostPicker({super.key, this.clips, this.posts});

  /// Tests pass their own lists.
  final Stream<List<Post>>? clips;
  final Stream<List<Post>>? posts;

  @override
  State<MyPostPicker> createState() => _MyPostPickerState();
}

class _MyPostPickerState extends State<MyPostPicker> {
  late final Stream<List<Post>> _clips =
      widget.clips ??
      PostRepository.instance.byUser(
        UserRepository.instance.myUid,
        type: Post.clip,
      );
  late final Stream<List<Post>> _posts =
      widget.posts ??
      PostRepository.instance.byUser(
        UserRepository.instance.myUid,
        type: Post.photo,
      );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            const TabBar(
              tabs: [
                Tab(text: 'Clips'),
                Tab(text: 'Posts'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [_grid(_clips, 'No clips yet'), _grid(_posts, 'No posts yet')],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _grid(Stream<List<Post>> stream, String empty) {
    return StreamBuilder<List<Post>>(
      stream: stream,
      builder: (context, snap) {
        if (snap.hasError) return ErrorView(error: snap.error);
        if (!snap.hasData) return const LoadingView();
        final list = snap.data!;
        if (list.isEmpty) {
          return Center(
            child: Text(
              empty,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(2),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
            childAspectRatio: 0.75,
          ),
          itemCount: list.length,
          itemBuilder: (context, i) {
            final p = list[i];
            return GestureDetector(
              key: ValueKey('pick-post-${p.id}'),
              onTap: () => Navigator.pop(context, p),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  NetImage(p.coverUrl),
                  if (p.isClip)
                    const Positioned(
                      right: 6,
                      top: 6,
                      child: Icon(
                        Icons.smart_display,
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// Small card of a clip / post inside a comment. Tap = open it.
class LinkedPostCard extends StatelessWidget {
  const LinkedPostCard({
    super.key,
    required this.thumb,
    required this.author,
    required this.isClip,
    this.onTap,
    this.width = 96,
  });

  final String thumb;
  final String author;
  final bool isClip;
  final VoidCallback? onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                aspectRatio: 0.75,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    NetImage(thumb),
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Icon(
                        isClip ? Icons.play_arrow_rounded : Icons.photo_outlined,
                        size: 20,
                        color: Colors.white,
                        shadows: const [
                          Shadow(blurRadius: 6, color: Colors.black54),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              "@$author's ${isClip ? 'clip' : 'post'}",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "↩ Reply to @name's comment" on a post / clip made as an answer.
/// Tap = open the post / clip the comment is under.
class ReplyStickerChip extends StatelessWidget {
  const ReplyStickerChip({super.key, required this.reply, this.onTap});
  final ReplyRef reply;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('reply-sticker'),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.reply_rounded, size: 15, color: AppColors.lime),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    reply.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            if (reply.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  reply.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
