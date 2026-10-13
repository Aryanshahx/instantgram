import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/services/app_settings.dart';
import '../../../core/services/content_filter.dart';
import '../../../core/services/media_service.dart';
import '../../../shared/models/post.dart';
import '../../notifications/data/notification_repository.dart';
import '../../../shared/models/user_profile.dart';
import '../../profile/data/user_repository.dart';
import '../../stories/data/story_repository.dart';

class PostRepository {
  PostRepository._();
  static final PostRepository instance = PostRepository._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _posts =>
      _db.collection('posts');
  String get _me => FirebaseAuth.instance.currentUser!.uid;

  List<Post> _map(QuerySnapshot<Map<String, dynamic>> s) =>
      s.docs.map(Post.fromDoc).toList();

  /// "#Sunset at #goa" -> ['sunset', 'goa']
  static List<String> extractTags(String text) {
    final tags = <String>{};
    for (final m in RegExp(
      r'#([\p{L}\p{M}\p{N}_]{1,50})',
      unicode: true,
    ).allMatches(text)) {
      tags.add(m.group(1)!.toLowerCase());
      if (tags.length >= 30) break;
    }
    return tags.toList();
  }

  /// Clips with a hashtag (newest first).
  Future<List<Post>> clipsByTag(String tag) async {
    final t = tag.replaceFirst('#', '').trim().toLowerCase();
    if (t.isEmpty) return [];
    // Single-field query -> no extra Firestore index needed.
    final s = await _posts.where('tags', arrayContains: t).limit(150).get();
    final list = _map(s).where((p) => p.isClip && _filter.canSee(p)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  // ---------------- Create / delete ----------------

  Map<String, dynamic> _base(UserProfile me, PostOptions o, String caption) => {
    'authorId': me.uid,
    'authorUsername': me.username,
    'authorPhotoUrl': me.photoUrl,
    'caption': caption.trim(),
    'tags': extractTags(caption),
    'likesCount': 0,
    'commentsCount': 0,
    'repostsCount': 0,
    'viewsCount': 0,
    'uniqueViews': 0,
    'sharesCount': 0,
    'savesCount': 0,
    'pinned': false,
    'audience': o.audience,
    'hideLikes': o.hideLikes,
    'hideComments': o.hideComments,
    'hideReposts': o.hideReposts,
    'hideShares': o.hideShares,
    'createdAt': FieldValue.serverTimestamp(),
  };

  /// Most items one post / clip may have (Firestore rules allow 200).
  static const int maxItems = 200;

  /// Creates a post or clip with any mix of photos and videos.
  /// [cover] = clip cover chosen by the user (else the first video frame).
  /// [audio] = music that plays in a loop.
  Future<void> createPost({
    required String type,
    required List<PostUpload> items,
    required String caption,
    File? cover,
    PickedAudio? audio,
    PostOptions options = const PostOptions(),
    ValueChanged<double>? onProgress,
  }) async {
    if (items.isEmpty) throw ArgumentError('Nothing to share');
    if (items.length > maxItems) {
      throw StateError('You can share up to $maxItems photos and videos');
    }
    final me = await UserRepository.instance.me();

    // ---- upload everything (progress by file size)
    final jobs = <(File, MediaKind)>[];
    for (final it in items) {
      // the folder only depends on the file type, so this also works
      // with older servers (videos -> clip, photos -> post)
      jobs.add((it.file, it.isVideo ? MediaKind.clip : MediaKind.post));
      final t = it.thumb;
      if (it.isVideo && t != null) jobs.add((t, MediaKind.thumb));
    }
    if (cover != null) jobs.add((cover, MediaKind.thumb));
    if (audio != null) jobs.add((audio.file, MediaKind.audio));
    final sizes = <int>[];
    for (final j in jobs) {
      sizes.add(await j.$1.length().catchError((Object _) => 1));
    }
    final total = sizes.fold<int>(0, (a, b) => a + b).clamp(1, 1 << 62);
    var done = 0;
    final uploaded = <UploadedMedia?>[];
    for (var i = 0; i < jobs.length; i++) {
      final (file, kind) = jobs[i];
      final base = done;
      final optional = kind == MediaKind.thumb;
      try {
        uploaded.add(
          await MediaService.instance.upload(
            file,
            kind: kind,
            onProgress: (v) =>
                onProgress?.call((base + sizes[i] * v) / total * 0.97),
          ),
        );
      } catch (e) {
        if (!optional) {
          if (kind == MediaKind.audio) {
            throw StateError('Could not upload the music ($e)');
          }
          rethrow;
        }
        uploaded.add(null); // a cover is optional
      }
      done += sizes[i];
    }

    // ---- build the media list
    var u = 0;
    final media = <MediaItem>[];
    for (final it in items) {
      final main = uploaded[u++]!;
      UploadedMedia? thumb;
      if (it.isVideo && it.thumb != null) thumb = uploaded[u++];
      media.add(
        MediaItem(
          url: main.url,
          key: main.key,
          aspectRatio: safeAspect(it.aspectRatio),
          isVideo: it.isVideo,
          thumbUrl: thumb?.url ?? '',
          thumbKey: thumb?.key ?? '',
          durationMs: it.isVideo ? it.durationMs : 0,
          edits: it.isVideo ? it.edits : const VideoEdits(),
        ),
      );
    }
    final coverUp = cover != null ? uploaded[u++] : null;
    final audioUp = audio != null ? uploaded[u++] : null;

    final first = media.first;
    final firstItem = items.first;
    // cover for grids: chosen cover, else the first item's image
    final coverUrl = coverUp?.url ?? first.coverUrl;
    final coverKey = coverUp?.key ?? (first.isVideo ? first.thumbKey : '');

    final ref = _posts.doc();
    final batch = _db.batch();
    batch.set(ref, {
      ..._base(me, options, caption),
      'type': type,
      'mediaUrl': first.url,
      'mediaKey': first.key,
      'aspectRatio': first.aspectRatio,
      'media': media.map((m) => m.toMap()).toList(),
      'itemCount': media.length,
      if (coverUrl.isNotEmpty) 'thumbUrl': coverUrl,
      if (coverKey.isNotEmpty) 'thumbKey': coverKey,
      // older app versions read these for a clip's first video
      if (first.isVideo && first.durationMs > 0) 'durationMs': first.durationMs,
      if (first.isVideo) ...firstItem.edits.toMap(),
      if (audioUp != null) ...{
        'audioUrl': audioUp.url,
        'audioKey': audioUp.key,
        'audioName': audio!.name,
      },
    });
    batch.update(_db.collection('users').doc(me.uid), {
      'postsCount': FieldValue.increment(1),
    });
    if (options.alsoMoment) {
      StoryRepository.instance.addSharedToBatch(
        batch,
        me: me,
        url: first.url,
        isVideo: first.isVideo,
        postId: ref.id,
        audience: options.audience,
        edits: first.edits,
        durationMs: first.durationMs,
      );
    }
    await batch.commit();
    onProgress?.call(1);
  }

  Future<void> delete(Post post) async {
    final batch = _db.batch();
    batch.delete(_posts.doc(post.id));
    batch.update(_db.collection('users').doc(post.authorId), {
      'postsCount': FieldValue.increment(-1),
    });
    await batch.commit();
    for (final k in post.allKeys) {
      MediaService.instance.delete(k);
    }
  }

  /// Owner changes who can see it / which counts are hidden.
  Future<void> updateOptions(Post post, Map<String, dynamic> fields) =>
      _posts.doc(post.id).update(fields);

  Future<void> setPinned(Post post, bool pinned) =>
      _posts.doc(post.id).update({'pinned': pinned});

  // ---------------- Queries ----------------

  Stream<Post?> watch(String id) => _posts
      .doc(id)
      .snapshots()
      .map((s) => s.exists ? Post.fromDoc(s) : null)
      // hidden (blocked / private / audience) -> treated as "not found"
      .map((p) => p == null || _filter.canSee(p) ? p : null);

  ContentFilter get _filter => ContentFilter.instance;

  /// Posts from a list of authors (max 30).
  Stream<List<Post>> feed(List<String> authorIds) => _filter.visiblePosts(
    _posts
        .where('authorId', whereIn: authorIds.take(30).toList())
        .orderBy('createdAt', descending: true)
        .limit(60)
        .snapshots()
        .map(_map),
  );

  /// Latest posts from everyone. [type] = Post.photo / Post.clip / null (all)
  Stream<List<Post>> recent({String? type, int limit = 60}) {
    Query<Map<String, dynamic>> q = _posts;
    if (type != null) q = q.where('type', isEqualTo: type);
    return _filter.visiblePosts(
      q
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .snapshots()
          .map(_map),
    );
  }

  Stream<List<Post>> byUser(String uid, {required String type}) =>
      _filter.visiblePosts(
        _posts
            .where('authorId', isEqualTo: uid)
            .where('type', isEqualTo: type)
            .orderBy('createdAt', descending: true)
            .limit(120)
            .snapshots()
            .map((s) {
              final list = _map(s);
              list.sort((a, b) {
                if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
                return b.createdAt.compareTo(a.createdAt);
              });
              return list;
            }),
      );

  Future<List<Post>> allByUser(String uid) async {
    final s = await _posts.where('authorId', isEqualTo: uid).limit(500).get();
    return _map(s);
  }

  Future<List<Post>> byIds(List<String> ids) async {
    final out = <Post>[];
    for (var i = 0; i < ids.length; i += 30) {
      final chunk = ids.sublist(i, i + 30 > ids.length ? ids.length : i + 30);
      final s = await _posts.where(FieldPath.documentId, whereIn: chunk).get();
      out.addAll(_map(s));
    }
    final byId = {for (final p in out) p.id: p};
    return [
      for (final id in ids)
        if (byId[id] != null && _filter.canSee(byId[id]!)) byId[id]!,
    ];
  }

  Stream<List<String>> savedIds() => _db
      .collection('users')
      .doc(_me)
      .collection('saved')
      .orderBy('createdAt', descending: true)
      .limit(300)
      .snapshots()
      .map((s) => s.docs.map((d) => d.id).toList());

  Stream<List<String>> repostIds(String uid) => _db
      .collection('users')
      .doc(uid)
      .collection('reposts')
      .orderBy('createdAt', descending: true)
      .limit(300)
      .snapshots()
      .map((s) => s.docs.map((d) => d.id).toList());

  // ---------------- Likes ----------------

  Stream<bool> isLiked(String postId) => _posts
      .doc(postId)
      .collection('likes')
      .doc(_me)
      .snapshots()
      .map((s) => s.exists);

  Future<void> setLiked(Post post, bool like) async {
    final ref = _posts.doc(post.id);
    final batch = _db.batch();
    if (like) {
      final me = await UserRepository.instance.meCached();
      batch.set(ref.collection('likes').doc(_me), {
        'createdAt': FieldValue.serverTimestamp(),
      });
      batch.update(ref, {'likesCount': FieldValue.increment(1)});
      NotificationRepository.instance.addToBatch(
        batch,
        toUid: post.authorId,
        from: me,
        type: AppNotification.like,
        post: post,
      );
    } else {
      batch.delete(ref.collection('likes').doc(_me));
      batch.update(ref, {'likesCount': FieldValue.increment(-1)});
    }
    await batch.commit();
  }

  // ---------------- Save / repost ----------------

  Stream<bool> isSaved(String postId) => _db
      .collection('users')
      .doc(_me)
      .collection('saved')
      .doc(postId)
      .snapshots()
      .map((s) => s.exists);

  /// Save / unsave (+ keeps savesCount in step for Analytics).
  Future<void> setSaved(Post post, bool save) async {
    final ref = _db
        .collection('users')
        .doc(_me)
        .collection('saved')
        .doc(post.id);
    final exists = (await ref.get()).exists;
    if (exists == save) return;
    final batch = _db.batch();
    if (save) {
      batch.set(ref, {'createdAt': FieldValue.serverTimestamp()});
    } else {
      batch.delete(ref);
    }
    batch.update(_posts.doc(post.id), {
      'savesCount': FieldValue.increment(save ? 1 : -1),
    });
    try {
      await batch.commit();
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied' && e.code != 'not-found') rethrow;
      // old rules / deleted post: still save it for you
      save
          ? await ref.set({'createdAt': FieldValue.serverTimestamp()})
          : await ref.delete();
    }
  }

  Stream<bool> isReposted(String postId) => _db
      .collection('users')
      .doc(_me)
      .collection('reposts')
      .doc(postId)
      .snapshots()
      .map((s) => s.exists);

  Future<void> setReposted(Post post, bool repost) async {
    final ref = _db
        .collection('users')
        .doc(_me)
        .collection('reposts')
        .doc(post.id);
    final batch = _db.batch();
    if (repost) {
      final me = await UserRepository.instance.meCached();
      batch.set(ref, {'createdAt': FieldValue.serverTimestamp()});
      batch.update(_posts.doc(post.id), {
        'repostsCount': FieldValue.increment(1),
      });
      NotificationRepository.instance.addToBatch(
        batch,
        toUid: post.authorId,
        from: me,
        type: AppNotification.repost,
        post: post,
      );
    } else {
      batch.delete(ref);
      batch.update(_posts.doc(post.id), {
        'repostsCount': FieldValue.increment(-1),
      });
    }
    await batch.commit();
  }

  // ---------------- Comments ----------------

  Stream<List<Comment>> comments(String postId) => _posts
      .doc(postId)
      .collection('comments')
      .orderBy('createdAt')
      .limit(300)
      .snapshots()
      .map(
        (s) => s.docs
            .map(Comment.fromDoc)
            .where((c) => !_filter.isBlocked(c.authorId))
            .toList(),
      );

  Future<void> addComment(Post post, String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final me = await UserRepository.instance.meCached();
    final ref = _posts.doc(post.id);
    final batch = _db.batch();
    batch.set(ref.collection('comments').doc(), {
      'authorId': me.uid,
      'authorUsername': me.username,
      'authorPhotoUrl': me.photoUrl,
      'text': t,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(ref, {'commentsCount': FieldValue.increment(1)});
    NotificationRepository.instance.addToBatch(
      batch,
      toUid: post.authorId,
      from: me,
      type: AppNotification.comment,
      post: post,
      text: t,
    );
    await batch.commit();
  }

  Future<void> deleteComment(String postId, String commentId) async {
    final ref = _posts.doc(postId);
    final batch = _db.batch();
    batch.delete(ref.collection('comments').doc(commentId));
    batch.update(ref, {'commentsCount': FieldValue.increment(-1)});
    await batch.commit();
  }

  // ---------------- Views ----------------
  //
  // One view doc per account: posts/{pid}/views/{uid}.
  // viewsCount goes up only when that doc is created, and never for the
  // author. The doc keeps simple facts for the author's Analytics
  // (follower?, country, age range, language, where it was seen, watch time).

  final Set<String> _sessionViewed = {};
  final Map<String, int> _sentWatch = {};
  String? _ageGroup;

  /// Counts a view (once per account) + adds it to History.
  Future<void> addView(Post post, {String source = ViewSource.other}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (!_sessionViewed.add(post.id)) return; // once per app run
    AppSettings.instance.addHistory(post.id, isClip: post.isClip);
    if (post.authorId == uid) return; // your own views don't count
    final ref = _posts.doc(post.id).collection('views').doc(uid);
    try {
      var known = AppSettings.instance.hasViewed(post.id);
      if (!known) known = (await ref.get()).exists;
      if (known) {
        AppSettings.instance.markViewed(post.id);
        await ref.update({
          'count': FieldValue.increment(1),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return;
      }
      final batch = _db.batch();
      batch.set(ref, {
        ...await _viewerInfo(post.authorId),
        'source': ViewSource.normalize(source),
        'count': 1,
        'watchMs': 0,
        'completed': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
      batch.update(_posts.doc(post.id), {
        'uniqueViews': FieldValue.increment(1),
      });
      await batch.commit();
      AppSettings.instance.markViewed(post.id);
    } catch (e) {
      debugPrint('addView failed: $e');
    }
  }

  /// Saves how long a video was watched (only goes up).
  Future<void> reportWatch(
    Post post, {
    required int watchMs,
    required bool completed,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || post.authorId == uid || watchMs <= 0) return;
    final ms = watchMs.clamp(0, 6 * 60 * 60 * 1000);
    final prev = _sentWatch[post.id] ?? 0;
    if (ms <= prev && !completed) return;
    _sentWatch[post.id] = ms > prev ? ms : prev;
    try {
      await _posts.doc(post.id).collection('views').doc(uid).update({
        'watchMs': ms > prev ? ms : prev,
        if (completed) 'completed': true,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // no view doc yet (offline) -> skip
    }
  }

  Future<Map<String, dynamic>> _viewerInfo(String authorId) async {
    var country = '', language = '';
    try {
      final me = await UserRepository.instance.meCached();
      country = me.country;
      language = me.language;
    } catch (_) {}
    if (_ageGroup == null) {
      try {
        final d = DateTime.tryParse(await UserRepository.instance.birthDate());
        _ageGroup = d == null ? '' : ageGroupOf(ageOn(d, DateTime.now()));
      } catch (_) {
        _ageGroup = '';
      }
    }
    return {
      'follower': _filter.isFollowing(authorId),
      if (country.isNotEmpty) 'country': country,
      if (language.isNotEmpty) 'language': language,
      if (_ageGroup!.isNotEmpty) 'ageGroup': _ageGroup,
    };
  }

  /// Author only: every view doc of one post (for Analytics).
  Future<List<Map<String, dynamic>>> viewDocs(String postId) async {
    final s = await _posts.doc(postId).collection('views').limit(5000).get();
    return s.docs.map((d) => d.data()).toList();
  }

  // ---------------- Shares ----------------

  /// +1 share (anyone can add one).
  Future<void> addShare(Post post) async {
    try {
      await _posts.doc(post.id).update({
        'sharesCount': FieldValue.increment(1),
      });
    } catch (_) {}
  }
}

/// Options picked on the share screen.
class PostOptions {
  const PostOptions({
    this.audience = Audience.everyone,
    this.alsoMoment = false,
    this.hideLikes = false,
    this.hideComments = false,
    this.hideReposts = false,
    this.hideShares = false,
  });

  final String audience;
  final bool alsoMoment;
  final bool hideLikes;
  final bool hideComments;
  final bool hideReposts;
  final bool hideShares;
}

/// One edited photo ready to upload.
/// One photo or video to upload.
class PostUpload {
  const PostUpload({
    required this.file,
    required this.isVideo,
    required this.aspectRatio,
    this.edits = const VideoEdits(),
    this.durationMs = 0,
    this.thumb,
  });

  final File file;
  final bool isVideo;
  final double aspectRatio;
  final VideoEdits edits;
  final int durationMs;

  /// Video cover frame (already filtered).
  final File? thumb;
}

/// Where a view came from (for Analytics).
class ViewSource {
  ViewSource._();
  static const String feed = 'feed';
  static const String clips = 'clips';
  static const String profile = 'profile';
  static const String explore = 'explore';
  static const String other = 'other';

  static const List<String> all = [feed, clips, profile, explore, other];

  static String normalize(String s) => all.contains(s) ? s : other;

  static String label(String s) => switch (s) {
    feed => 'Discover',
    clips => 'Clips',
    profile => 'Profile',
    explore => 'Explore and search',
    _ => 'Other (shares, notifications)',
  };
}

/// Age -> age range used in Analytics.
String ageGroupOf(int age) {
  if (age < 13) return '';
  if (age < 18) return '13-17';
  if (age < 25) return '18-24';
  if (age < 35) return '25-34';
  if (age < 45) return '35-44';
  if (age < 55) return '45-54';
  return '55+';
}

const List<String> kAgeGroups = [
  '13-17',
  '18-24',
  '25-34',
  '35-44',
  '45-54',
  '55+',
];
