import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../core/ui.dart';
import '../services/post_service.dart';

/// Where likes are read and written (tests swap it).
class LikeApi {
  const LikeApi({
    required this.state,
    required this.setLike,
    required this.sendSuper,
  });

  final Future<({bool liked, bool superHeart})> Function(String postId) state;
  final Future<void> Function(String postId, bool like, bool wasSuper) setLike;
  final Future<void> Function(String postId, bool alreadyLiked) sendSuper;

  static LikeApi? debug;

  static LikeApi get current =>
      debug ??
      LikeApi(
        state: PostService.instance.likeState,
        setLike: (id, like, wasSuper) =>
            PostService.instance.setLike(id, like, wasSuper: wasSuper),
        sendSuper: (id, already) =>
            PostService.instance.sendSuperHeart(id, alreadyLiked: already),
      );
}

/// Optimistic like state for a single post (plus its super heart).
class LikeController extends ChangeNotifier {
  LikeController(this.postId, this.count, {this.superCount = 0}) {
    _load();
  }

  final String postId;
  bool liked = false;

  /// I sent this post a super heart (one per person).
  bool superHeart = false;
  int count;
  int superCount;
  bool _busy = false;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _load() async {
    try {
      final v = await LikeApi.current.state(postId);
      if (_disposed) return;
      liked = v.liked;
      superHeart = v.superHeart;
      notifyListeners();
    } catch (_) {}
  }

  /// Returns an error if the write failed (state is rolled back).
  Future<Object?> setLiked(bool value) async {
    if (_busy || liked == value) return null;
    _busy = true;
    final wasSuper = superHeart;
    liked = value;
    count += value ? 1 : -1;
    if (count < 0) count = 0;
    if (!value && wasSuper) {
      superHeart = false;
      superCount = superCount > 0 ? superCount - 1 : 0;
    }
    _notify();
    try {
      await LikeApi.current.setLike(postId, value, wasSuper);
      return null;
    } catch (e) {
      liked = !value;
      count += value ? -1 : 1;
      if (!value && wasSuper) {
        superHeart = true;
        superCount++;
      }
      _notify();
      return e;
    } finally {
      _busy = false;
    }
  }

  Future<Object?> toggle() => setLiked(!liked);

  /// Sends a super heart (it also likes the post). False if one was already sent.
  /// Throws if the write failed (state is rolled back).
  Future<bool> sendSuper() async {
    if (_busy || superHeart) return false;
    _busy = true;
    final wasLiked = liked;
    superHeart = true;
    superCount++;
    if (!wasLiked) {
      liked = true;
      count++;
    }
    _notify();
    try {
      await LikeApi.current.sendSuper(postId, wasLiked);
      return true;
    } catch (e) {
      superHeart = false;
      superCount = superCount > 0 ? superCount - 1 : 0;
      if (!wasLiked) {
        liked = false;
        count = count > 0 ? count - 1 : 0;
      }
      _notify();
      rethrow;
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Long-press on a heart: send a super heart, with the burst. Says so when one was already sent.
Future<void> superHeartFrom(BuildContext context, LikeController like) async {
  if (like.superHeart) {
    showToast(context, 'You already sent a super heart here.');
    return;
  }
  showSuperHeartBurst(context);
  try {
    await like.sendSuper();
  } catch (e) {
    if (context.mounted) showToast(context, friendlyError(e));
  }
}

/// The colour of a super heart.
const Color kSuperHeartColor = Color(0xFFC64BFF);

/// A big glowing heart with small hearts flying out, over everything, for a moment.
void showSuperHeartBurst(BuildContext context) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => IgnorePointer(child: _Burst(onDone: () => entry.remove())),
  );
  overlay.insert(entry);
}

class _Burst extends StatefulWidget {
  const _Burst({required this.onDone});
  final VoidCallback onDone;

  @override
  State<_Burst> createState() => _BurstState();
}

class _BurstState extends State<_Burst> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..forward().whenComplete(widget.onDone);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, _) {
      final t = _c.value;
      final grow = Curves.elasticOut.transform((t * 1.6).clamp(0.0, 1.0));
      final fade = t < 0.7 ? 1.0 : 1 - (t - 0.7) / 0.3;
      return Opacity(
        key: const ValueKey('superBurst'),
        opacity: fade.clamp(0.0, 1.0),
        child: Center(
          child: SizedBox(
            width: 260,
            height: 260,
            child: Stack(
              alignment: Alignment.center,
              children: [
                for (var k = 0; k < 10; k++)
                  Transform.translate(
                    offset: Offset.fromDirection(
                      k * math.pi / 5,
                      30 + 100 * Curves.easeOut.transform(t),
                    ),
                    child: Icon(
                      Icons.favorite_rounded,
                      size: 18 + (k % 3) * 6,
                      color: (k.isEven ? kSuperHeartColor : kHeartColor)
                          .withValues(alpha: 0.9),
                    ),
                  ),
                Transform.scale(
                  scale: 0.2 + grow,
                  child: ShaderMask(
                    shaderCallback: (r) => const LinearGradient(
                      colors: [kHeartColor, kSuperHeartColor],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ).createShader(r),
                    child: const Icon(
                      Icons.favorite_rounded,
                      size: 120,
                      color: Colors.white,
                      shadows: [
                        Shadow(color: kSuperHeartColor, blurRadius: 30),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// The colour of a liked heart.
const Color kHeartColor = Color(0xFFFF3B5C);

/// Heart + count, no background. Used under posts (super hearts are for moments only).
class HeartButton extends StatelessWidget {
  const HeartButton({
    super.key,
    required this.controller,
    this.size = 24,
    this.onError,
    this.showCount = true,
  });

  final LikeController controller;
  final double size;

  /// False when the author hid the like count (the author still sees it).
  final bool showCount;
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
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedScale(
                  scale: liked ? 1.14 : 1,
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
                if (showCount) ...[
                  const SizedBox(width: 5),
                  Text(
                    '${controller.count}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
