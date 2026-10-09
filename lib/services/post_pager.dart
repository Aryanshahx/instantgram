import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/post.dart';
import 'safety_service.dart';

/// Cursor-based pagination (keeps Firestore reads low on the free tier).
class PostPager extends ChangeNotifier {
  PostPager(
    this._build, {
    this.pageSize = 10,
    this.first,
    this.feed = false,
    this.seed,
    this.arrange,
    this.fetchPage,
  }) {
    if (first != null) posts.add(first!);
  }

  final Query<Map<String, dynamic>> Function() _build;
  final int pageSize;

  /// Shown at the top of the list (a clip the user tapped); the loaded pages skip it.
  final Post? first;

  /// Home, Clips and Explore: posts the author keeps "only on my profile" are left out.
  final bool feed;

  /// Extra posts mixed into the first page (trending posts for For you and Clips).
  final Future<List<Post>> Function()? seed;

  /// Puts each loaded page in order (the For you ranking); null = newest first.
  final List<Post> Function(List<Post> page, Set<String> seeded)? arrange;

  /// Tests: loads page n (0, 1, ...) instead of asking Firestore.
  final Future<List<Post>> Function(int page)? fetchPage;
  int _pageNo = 0;

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
      final seedFn = seed;
      final firstPage = reset || _pageNo == 0;
      if (reset) _pageNo = 0;
      final fake = fetchPage;
      final results = await Future.wait<Object>([
        if (fake != null)
          fake(_pageNo)
        else
          (() {
            var q = _build().limit(pageSize);
            if (!reset && _cursor != null) q = q.startAfterDocument(_cursor!);
            return q.get();
          })(),
        if (seedFn != null && firstPage) _safeSeed(seedFn),
      ]);
      final got = results[0];
      final snap = got is QuerySnapshot<Map<String, dynamic>> ? got : null;
      final loaded = snap == null
          ? got as List<Post>
          : snap.docs.map(Post.fromDoc).toList();
      final extra = results.length > 1 ? results[1] as List<Post> : <Post>[];
      if (reset) {
        posts.clear();
        if (first != null) posts.add(first!);
        _cursor = null;
      }
      _pageNo++;
      final have = {for (final p in posts) p.id};
      final page = <Post>[];
      for (final p in [...extra, ...loaded]) {
        if (p.isLegacyLink ||
            p.id == first?.id ||
            (feed && p.profileOnly) ||
            !SafetyService.instance.canSee(p) ||
            !have.add(p.id)) {
          continue;
        }
        page.add(p);
      }
      final order = arrange;
      posts.addAll(
        order == null ? page : order(page, {for (final p in extra) p.id}),
      );
      if (snap != null && snap.docs.isNotEmpty) _cursor = snap.docs.last;
      hasMore = loaded.length >= pageSize;
    } catch (e) {
      error = e;
    } finally {
      loading = false;
      _notify();
    }
  }

  static Future<List<Post>> _safeSeed(Future<List<Post>> Function() f) async {
    try {
      return await f();
    } catch (_) {
      return const <Post>[];
    }
  }

  void removeById(String id) {
    posts.removeWhere((p) => p.id == id);
    _notify();
  }
}
