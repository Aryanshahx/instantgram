import 'package:flutter/foundation.dart';

import '../models/post.dart';
import '../services/post_service.dart';

/// Optimistic repost state for one post.
class RepostController extends ChangeNotifier {
  RepostController(this.post, {Future<bool> Function(String id)? loader}) {
    _load(loader ?? PostService.instance.isReposted);
  }

  final Post post;
  bool reposted = false;

  /// How many people reposted it (changes at once when you repost).
  late int count = post.repostCount;
  bool _busy = false;
  bool _disposed = false;

  Future<void> _load(Future<bool> Function(String id) loader) async {
    try {
      final v = await loader(post.id);
      if (_disposed) return;
      reposted = v;
      notifyListeners();
    } catch (_) {}
  }

  /// Returns an error if the write failed (state is rolled back).
  Future<Object?> toggle() async {
    if (_busy) return null;
    _busy = true;
    final target = !reposted;
    reposted = target;
    count = (count + (target ? 1 : -1)).clamp(0, 1 << 30);
    notifyListeners();
    try {
      await PostService.instance.setReposted(post, target);
      return null;
    } catch (e) {
      reposted = !target;
      count = (count + (target ? -1 : 1)).clamp(0, 1 << 30);
      if (!_disposed) notifyListeners();
      return e;
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
