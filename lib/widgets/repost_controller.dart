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
    notifyListeners();
    try {
      await PostService.instance.setReposted(post, target);
      return null;
    } catch (e) {
      reposted = !target;
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
