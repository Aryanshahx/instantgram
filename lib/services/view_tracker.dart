import 'dart:async';
import 'dart:ui' show VoidCallback;

import '../models/post.dart';
import 'app_prefs.dart';
import 'post_service.dart';
import 'user_service.dart';

/// Counts a view when someone really watches a post or a clip (a moment on screen, not a
/// scroll-past). Each person counts once per post, your own views are not counted.
class ViewTracker {
  ViewTracker._();
  static final ViewTracker instance = ViewTracker._();

  final Set<String> _done = {};

  /// How long a post has to be on screen to count.
  static const Duration watchTime = Duration(milliseconds: 1500);

  /// Starts the timer; call the returned function to cancel it (the post left the screen).
  VoidCallback watch(Post post) {
    final timer = Timer(watchTime, () => record(post));
    return timer.cancel;
  }

  Future<void> record(Post post) async {
    String me;
    try {
      me = UserService.instance.myUid;
    } catch (_) {
      return;
    }
    if (post.authorId == me || post.id.isEmpty) return;
    AppPrefs.instance.addHistory(post.id); // Settings > History
    if (!_done.add(post.id)) return;
    try {
      await PostService.instance.registerView(post.id);
    } catch (_) {
      _done.remove(post.id); // try again next time it is watched
    }
  }
}
