import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/post.dart';
import 'safety_service.dart';

/// Cursor-based pagination (keeps Firestore reads low on the free tier).
class PostPager extends ChangeNotifier {
  PostPager(this._build, {this.pageSize = 10, this.first, this.feed = false}) {
    if (first != null) posts.add(first!);
  }

  final Query<Map<String, dynamic>> Function() _build;
  final int pageSize;

  /// Shown at the top of the list (a clip the user tapped); the loaded pages skip it.
  final Post? first;

  /// Home, Clips and Explore: posts the author keeps "only on my profile" are left out.
  final bool feed;

  final List<Post> posts = [];
  DocumentSnapshot<Map<String, dynamic>>? _cursor;
  bool loading = false;
  bool hasMore = true;
  Object? error;
  bool _disposed = false;

  bool get initialLoading => loading && posts.isEmpty;
  bool get isEmpty => !loading && error == null && posts.isEmpty;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh() => _load(reset: true);

  Future<void> loadMore() => _load(reset: false);

  Future<void> retry() {
    error = null;
    return _load(reset: posts.isEmpty);
  }

  Future<void> _load({required bool reset}) async {
    if (loading) return;
    if (!reset && (!hasMore || error != null)) return;
    loading = true;
    error = null;
    _notify();
    try {
      var q = _build().limit(pageSize);
      if (!reset && _cursor != null) q = q.startAfterDocument(_cursor!);
      final snap = await q.get();
      if (reset) {
        posts.clear();
        if (first != null) posts.add(first!);
        _cursor = null;
      }
      posts.addAll(
        snap.docs
            .map(Post.fromDoc)
            .where(
              (p) =>
                  !p.isLegacyLink &&
                  p.id != first?.id &&
                  !(feed && p.profileOnly) &&
                  SafetyService.instance.canSee(p),
            ),
      );
      if (snap.docs.isNotEmpty) _cursor = snap.docs.last;
      hasMore = snap.docs.length >= pageSize;
    } catch (e) {
      error = e;
    } finally {
      loading = false;
      _notify();
    }
  }

  void removeById(String id) {
    posts.removeWhere((p) => p.id == id);
    _notify();
  }
}
