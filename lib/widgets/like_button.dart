import 'package:flutter/material.dart';

import '../services/post_service.dart';

/// Optimistic like state for a single post.
class LikeController extends ChangeNotifier {
  LikeController(this.postId, this.count) {
    _load();
  }

  final String postId;
  bool liked = false;
  int count;
  bool _busy = false;
  bool _disposed = false;

  Future<void> _load() async {
    try {
      final v = await PostService.instance.isLiked(postId);
      if (_disposed) return;
      liked = v;
      notifyListeners();
    } catch (_) {}
  }

  /// Returns an error if the write failed (state is rolled back).
  Future<Object?> setLiked(bool value) async {
    if (_busy || liked == value) return null;
    _busy = true;
    liked = value;
    count += value ? 1 : -1;
    if (count < 0) count = 0;
    notifyListeners();
    try {
      await PostService.instance.setLike(postId, value);
      return null;
    } catch (e) {
      liked = !value;
      count += value ? -1 : 1;
      if (!_disposed) notifyListeners();
      return e;
    } finally {
      _busy = false;
    }
  }

  Future<Object?> toggle() => setLiked(!liked);

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The colour of a liked heart.
const Color kHeartColor = Color(0xFFFF3B5C);

/// Heart + count, no background. Used under posts.
class HeartButton extends StatelessWidget {
  const HeartButton({
    super.key,
    required this.controller,
    this.size = 28,
    this.onError,
  });

  final LikeController controller;
  final double size;
  final void Function(Object error)? onError;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final liked = controller.liked;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () async {
            final err = await controller.toggle();
            if (err != null) onError?.call(err);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedScale(
                  scale: liked ? 1.18 : 1,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutBack,
                  child: Icon(
                    liked
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    size: size,
                    color: liked ? kHeartColor : null,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${controller.count}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14.5,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
