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
    'sharesCount': 0,
    'pinned': false,
    'audience': o.audience,
    'hideLikes': o.hideLikes,
    'hideComments': o.hideComments,
    'hideReposts': o.hideReposts,
    'hideShares': o.hideShares,
    'createdAt': FieldValue.serverTimestamp(),
  };

  /// Photo post with 1-10 photos (first one is the cover).
  Future<void> createPhotos({
    required List<PhotoUpload> photos,
    required String caption,
    PostOptions options = const PostOptions(),
    ValueChanged<double>? onProgress,
  }) async {
    if (photos.isEmpty) throw ArgumentError('No photos');
    final me = await UserRepository.instance.me();
    final items = <MediaItem>[];
    final n = photos.length;
    for (var i = 0; i < n; i++) {
      final up = await MediaService.instance.upload(
        photos[i].file,
        kind: MediaKind.post,
        onProgress: (v) => onProgress?.call((i + v) / n * 0.97),
      );
      items.add(
        MediaItem(url: up.url, key: up.key, aspectRatio: photos[i].aspectRatio),
      );
    }
    final ref = _posts.doc();
    final batch = _db.batch();
    batch.set(ref, {
      ..._base(me, options, caption),
      'type': Post.photo,
      'mediaUrl': items.first.url,
      'mediaKey': items.first.key,
      'aspectRatio': items.first.aspectRatio,
      'media': items.map((m) => m.toMap()).toList(),
    });
    batch.update(_db.collection('users').doc(me.uid), {
      'postsCount': FieldValue.increment(1),
    });
    if (options.alsoMoment) {
      StoryRepository.instance.addSharedToBatch(
        batch,
        me: me,
        url: items.first.url,
        isVideo: false,
        postId: ref.id,
        audience: options.audience,
      );
    }
    await batch.commit();
    onProgress?.call(1);
  }

  /// Clip: one video (+ optional cover image).
  Future<void> createClip({
    required File video,
    required double aspectRatio,
    required String caption,
    File? thumb,
    VideoEdits edits = const VideoEdits(),
    int durationMs = 0,
    PostOptions options = const PostOptions(),
    ValueChanged<double>? onProgress,
  }) async {
    final me = await UserRepository.instance.me();
    final media = await MediaService.instance.upload(
      video,
      kind: MediaKind.clip,
      onProgress: (v) => onProgress?.call(v * (thumb == null ? 0.97 : 0.9)),
    );
    UploadedMedia? cover;
    if (thumb != null) {
      try {
        cover = await MediaService.instance.upload(
          thumb,
          kind: MediaKind.thumb,
          onProgress: (v) => onProgress?.call(0.9 + v * 0.07),
        );
      } catch (_) {
        cover = null; // cover is optional
      }
    }
    final ref = _posts.doc();
    final batch = _db.batch();
    batch.set(ref, {
      ..._base(me, options, caption),
      'type': Post.clip,
      'mediaUrl': media.url,
      'mediaKey': media.key,
      'aspectRatio': aspectRatio,
      if (cover != null) 'thumbUrl': cover.url,
      if (cover != null) 'thumbKey': cover.key,
      if (durationMs > 0) 'durationMs': durationMs,
      ...edits.toMap(),
    });
    batch.update(_db.collection('users').doc(me.uid), {
      'postsCount': FieldValue.increment(1),
    });
    if (options.alsoMoment) {
      StoryRepository.instance.addSharedToBatch(
        batch,
        me: me,
        url: media.url,
        isVideo: true,
        postId: ref.id,
        audience: options.audience,
        edits: edits,
        durationMs: durationMs,
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

  Future<void> setSaved(Post post, bool save) {
    final ref = _db
        .collection('users')
        .doc(_me)
        .collection('saved')
        .doc(post.id);
    return save
        ? ref.set({'createdAt': FieldValue.serverTimestamp()})
        : ref.delete();
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

  final Set<String> _viewed = {};

  /// Counts one view per app session (+ adds it to History).
  Future<void> addView(Post post) async {
    if (_viewed.contains(post.id)) return;
    _viewed.add(post.id);
    AppSettings.instance.addHistory(post.id, isClip: post.isClip);
    try {
      await _posts.doc(post.id).update({'viewsCount': FieldValue.increment(1)});
    } catch (_) {}
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
class PhotoUpload {
  const PhotoUpload(this.file, this.aspectRatio);
  final File file;
  final double aspectRatio;
}
