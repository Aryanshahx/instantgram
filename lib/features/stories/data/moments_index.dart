import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/services/app_settings.dart';
import '../../../core/services/media_prefetch.dart';
import '../../../shared/models/post.dart';
import '../presentation/story_viewer_screen.dart';
import 'story_repository.dart';

/// Who has active moments right now (used for the glow ring everywhere).
class MomentsIndex {
  MomentsIndex._();
  static final MomentsIndex instance = MomentsIndex._();

  /// All visible moment groups (newest first).
  final ValueNotifier<List<StoryGroup>> groups = ValueNotifier(
    const <StoryGroup>[],
  );

  Map<String, StoryGroup> _byAuthor = const {};
  StreamSubscription<List<StoryGroup>>? _sub;
  Timer? _expiry;

  /// Rebuild when moments or "seen" change.
  Listenable get listenable =>
      Listenable.merge([groups, AppSettings.instance.seenMoments]);

  void start() {
    if (_sub != null) return;
    AppSettings.instance.load();
    _sub = StoryRepository.instance.active().listen(
      _set,
      onError: (Object _) {},
    );
    // moments expire while the app is open -> re-check every minute
    _expiry = Timer.periodic(const Duration(minutes: 1), (_) {
      final all = groups.value.expand((g) => g.stories).toList();
      final fresh = groupStories(all);
      if (fresh.length != groups.value.length ||
          fresh.fold<int>(0, (n, g) => n + g.stories.length) != all.length) {
        _set(fresh);
      }
    });
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _expiry?.cancel();
    _expiry = null;
    _set(const []);
  }

  void _set(List<StoryGroup> list) {
    _byAuthor = {for (final g in list) g.authorId: g};
    groups.value = list;
    _warm(list);
  }

  /// Downloads the first unseen photo of each group (max 12) and opens the
  /// first video, so tapping a ring shows the moment instantly.
  void _warm(List<StoryGroup> list) {
    final allowed = _allowed;
    if (allowed == null) return;
    var videos = 0;
    for (final g in list.where((g) => allowed.contains(g.authorId)).take(12)) {
      final st = g.stories.firstWhere(
        (s) => !AppSettings.instance.isSeen(s.id),
        orElse: () => g.stories.first,
      );
      if (st.isVideo) {
        if (videos++ < 1) VideoPool.instance.prefetch(st.mediaUrl);
      } else {
        MediaPrefetch.instance.image(st.mediaUrl);
      }
    }
  }

  /// For tests / previews.
  @visibleForTesting
  void debugSet(List<StoryGroup> list) => _set(list);

  Set<String>? _allowed;

  /// Whose moments go in the Discover row: me + following + famous.
  void setAllowed(Set<String> ids) {
    if (_allowed != null && setEquals(_allowed, ids)) return;
    _allowed = ids;
    _warm(groups.value);
  }

  /// Groups for the Discover row (only allowed authors), viewer order.
  List<StoryGroup> rowGroups(String myUid, Set<String> allowed) =>
      ordered(first: myUid)
          .where((g) => g.authorId == myUid || allowed.contains(g.authorId))
          .toList();

  StoryGroup? of(String uid) => _byAuthor[uid];
  bool has(String uid) => _byAuthor.containsKey(uid);

  bool allSeen(StoryGroup g) =>
      g.stories.every((s) => AppSettings.instance.isSeen(s.id));

  /// Groups for the viewer: [first] author first, then unseen, then seen.
  List<StoryGroup> ordered({String? first}) {
    final list = [...groups.value];
    list.sort((a, b) {
      if (a.authorId == first) return -1;
      if (b.authorId == first) return 1;
      final sa = allSeen(a), sb = allSeen(b);
      if (sa != sb) return sa ? 1 : -1;
      return 0;
    });
    return list;
  }

  /// Opens the viewer at [uid]'s moments. Returns false if none.
  bool open(BuildContext context, String uid) {
    final g = of(uid);
    if (g == null) return false;
    final list = ordered(first: uid);
    openStoryViewer(context, list, list.indexOf(g));
    return true;
  }
}

/// Opens the full-screen moment viewer.
Future<void> openStoryViewer(
  BuildContext context,
  List<StoryGroup> groups,
  int index,
) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      pageBuilder: (_, a, b) =>
          StoryViewerScreen(groups: groups, initialGroup: index),
      transitionsBuilder: (_, a, b, child) =>
          FadeTransition(opacity: a, child: child),
    ),
  );
}
