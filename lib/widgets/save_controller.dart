import 'package:flutter/foundation.dart';

import '../services/post_service.dart';

/// Optimistic bookmark state for one post.
class SaveController extends ChangeNotifier {
  SaveController(this.postId) {
    _load();
  }

  final String postId;
  bool saved = false;
  bool _busy = false;
  bool _disposed = false;

  Future<void> _load() async {
    try {
      final v = await PostService.instance.isSaved(postId);
      if (_disposed) return;
      saved = v;
      notifyListeners();
    } catch (_) {}
  }

  /// Returns an error if the write failed (state is rolled back).
  Future<Object?> toggle() async {
    if (_busy) return null;
    _busy = true;
    final target = !saved;
    saved = target;
    notifyListeners();
    try {
      await PostService.instance.setSaved(postId, target);
      return null;
    } catch (e) {
      saved = !target;
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
