import 'package:flutter/material.dart';

import '../core/services/app_settings.dart';
import '../features/post/data/post_repository.dart' show ViewSource;
import '../features/post/presentation/post_detail_screen.dart';
import '../features/profile/presentation/profile_screen.dart';
import '../features/reels/presentation/clips_screen.dart';
import 'models/post.dart';

void openProfile(BuildContext context, String uid) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ProfileScreen(uid: uid, standalone: true),
    ),
  );
}

/// Photo -> detail page. Clip -> full-screen clips player (swipe through clips).
/// Opens a clip (full screen list) or a post page.
/// [source] tells Analytics where the view came from.
void openPost(
  BuildContext context,
  List<Post> posts,
  int index, {
  String source = ViewSource.profile,
}) {
  final post = posts[index];
  if (post.isClip) {
    final clips = posts.where((p) => p.isClip).toList();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ClipsScreen(
          clips: clips,
          initialIndex: clips.indexWhere((p) => p.id == post.id),
          source: source,
        ),
      ),
    );
  } else {
    AppSettings.instance.addHistory(post.id, isClip: false);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PostDetailScreen(postId: post.id, source: source),
      ),
    );
  }
}
