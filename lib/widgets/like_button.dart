import 'package:flutter/material.dart';

import '../core/theme.dart';
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

/// Bolt "spark" pill shown on top of images.
class LikePill extends StatelessWidget {
  const LikePill({super.key, required this.controller, this.onError});

  final LikeController controller;
  final void Function(Object error)? onError;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final liked = controller.liked;
        final fg = liked ? AppTheme.ink : Colors.white;
        return GestureDetector(
          onTap: () async {
            final err = await controller.toggle();
            if (err != null) onError?.call(err);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: liked ? AppTheme.volt : Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedScale(
                  scale: liked ? 1.25 : 1,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutBack,
                  child: Icon(Icons.bolt_rounded, size: 20, color: fg),
                ),
                const SizedBox(width: 4),
                Text('${controller.count}',
                    style: TextStyle(
                        color: fg, fontWeight: FontWeight.w800, fontSize: 13)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Round bolt button (used in the Clips rail).
class LikeIconButton extends StatelessWidget {
  const LikeIconButton({super.key, required this.controller, this.size = 50, this.onError});

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
          onTap: () async {
            final err = await controller.toggle();
            if (err != null) onError?.call(err);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: liked ? AppTheme.volt : Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: AnimatedScale(
              scale: liked ? 1.2 : 1,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutBack,
              child: Icon(Icons.bolt_rounded,
                  size: size * 0.55, color: liked ? AppTheme.ink : Colors.white),
            ),
          ),
        );
      },
    );
  }
}
