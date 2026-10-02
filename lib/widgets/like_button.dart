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

class LikeIconButton extends StatelessWidget {
  const LikeIconButton({
    super.key,
    required this.controller,
    this.size = 28,
    this.color,
    this.onError,
  });

  final LikeController controller;
  final double size;
  final Color? color;
  final void Function(Object error)? onError;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return IconButton(
          iconSize: size,
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(minWidth: size + 12, minHeight: size + 12),
          onPressed: () async {
            final err = await controller.toggle();
            if (err != null) onError?.call(err);
          },
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
            child: Icon(
              controller.liked ? Icons.favorite : Icons.favorite_border,
              key: ValueKey(controller.liked),
              color: controller.liked ? Colors.redAccent : color,
            ),
          ),
        );
      },
    );
  }
}
