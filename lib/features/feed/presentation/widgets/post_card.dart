import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/time_ago.dart';
import '../../../../shared/models/post.dart';
import '../../../../shared/widgets/avatar.dart';
import '../../../../shared/widgets/net_image.dart';

class PostCard extends StatefulWidget {
  const PostCard({super.key, required this.post});

  final Post post;

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard>
    with SingleTickerProviderStateMixin {
  bool _liked = false;
  bool _saved = false;
  late final AnimationController _heart = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void dispose() {
    _heart.dispose();
    super.dispose();
  }

  void _toggleLike() => setState(() => _liked = !_liked);

  void _doubleTapLike() {
    setState(() => _liked = true);
    _heart.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.post;
    final likes = p.likes + (_liked ? 1 : 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
          child: Row(
            children: [
              Avatar(url: p.avatarUrl, name: p.username, size: 38),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  p.username,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(onPressed: () {}, icon: const Icon(Icons.more_horiz)),
            ],
          ),
        ),
        // Media
        GestureDetector(
          onDoubleTap: _doubleTapLike,
          child: AspectRatio(
            aspectRatio: p.aspectRatio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                NetImage(p.imageUrl),
                Center(
                  child: AnimatedBuilder(
                    animation: _heart,
                    builder: (context, _) {
                      final t = _heart.value;
                      if (t == 0 || t == 1) return const SizedBox.shrink();
                      final scale = t < 0.3
                          ? t / 0.3 * 1.2
                          : 1.2 - (t - 0.3) * 0.3;
                      return Opacity(
                        opacity: t < 0.7 ? 1 : (1 - t) / 0.3,
                        child: Transform.scale(
                          scale: scale,
                          child: const Icon(
                            Icons.favorite,
                            size: 110,
                            color: Colors.white,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        // Actions
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              IconButton(
                onPressed: _toggleLike,
                icon: Icon(
                  _liked ? Icons.favorite : Icons.favorite_border,
                  color: _liked ? AppColors.like : null,
                  size: 28,
                ),
              ),
              IconButton(
                onPressed: () {},
                icon: const Icon(Icons.chat_bubble_outline, size: 26),
              ),
              IconButton(
                onPressed: () {},
                icon: const Icon(Icons.repeat, size: 27),
              ),
              IconButton(
                onPressed: () {},
                icon: const Icon(Icons.send_outlined, size: 26),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => setState(() => _saved = !_saved),
                icon: Icon(
                  _saved ? Icons.bookmark : Icons.bookmark_border,
                  size: 28,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${compactCount(likes)} likes',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              if (p.caption.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${p.username} ',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(text: p.caption),
                    ],
                  ),
                ),
              ],
              if (p.comments > 0) ...[
                const SizedBox(height: 4),
                Text(
                  'View all ${p.comments} comments',
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                timeAgo(p.createdAt),
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
