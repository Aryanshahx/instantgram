import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/app_user.dart';
import '../models/comment.dart';
import '../models/finish.dart';
import '../models/music.dart';
import '../models/post.dart';
import 'post_search.dart';
import 'media_server.dart';
import 'notification_service.dart';
import 'safety_service.dart';
import 'user_service.dart';

typedef PostQuery = Query<Map<String, dynamic>>;

class PostService {
  PostService._();
  static final PostService instance = PostService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _posts =>
      _db.collection('posts');
  String get _uid => FirebaseAuth.instance.currentUser!.uid;

  // ----------------------------------------------------------------- queries

  PostQuery latestQuery() => _posts.orderBy('createdAt', descending: true);

  /// needs composite index: authorId ASC + createdAt DESC
  PostQuery userPostsQuery(String uid) => _posts
      .where('authorId', isEqualTo: uid)
      .orderBy('createdAt', descending: true);

  /// needs composite index: authorId ASC + createdAt DESC (same as above)
  PostQuery followingQuery(List<String> authorIds) => _posts
      .where('authorId', whereIn: authorIds)
      .orderBy('createdAt', descending: true);

  /// Videos and photo clips. Uses the composite index type ASC + createdAt DESC.
  PostQuery videoQuery() => _posts
      .where('type', whereIn: ['video', 'photoclip'])
      .orderBy('createdAt', descending: true);

  Future<Post?> getPost(String id) async {
    final d = await _posts.doc(id).get();
    return d.exists ? Post.fromDoc(d) : null;
  }

  // ------------------------------------------------------------------ search

  List<Post> _pool = const [];
  DateTime? _poolAt;

  /// Posts and clips whose title (caption), #hashtags or author match [query]. The newest
  /// 300 posts are searched on the phone (and kept for a minute), so old posts work too and
  /// nothing extra has to be stored.
  Future<List<Post>> searchPosts(String query) async {
    final at = _poolAt;
    if (at == null || DateTime.now().difference(at).inSeconds > 60) {
      final snap = await latestQuery().limit(300).get();
      _pool = snap.docs
          .map(Post.fromDoc)
          .where((p) => !p.isLegacyLink)
          .toList();
      _poolAt = DateTime.now();
    }
    return SafetyService.instance.visible(filterPosts(_pool, query));
  }

  /// Popular hashtags among the newest posts.
  Future<List<String>> trending() async {
    await searchPosts(' '); // loads the pool
    return trendingTags(SafetyService.instance.visible(_pool));
  }

  // ------------------------------------------------------------------ create

  Future<AppUser> _me() async {
    final me = await UserService.instance.getUser(_uid);
    if (me == null) throw StateError('Profile not found');
    return me;
  }

  /// Returns the stored reference of the photo.
  Future<String> createImagePost({
    required File image,
    required String caption,
    void Function(double progress)? onProgress,
    int width = 0,
    int height = 0,
    String? musicId,
    String? musicTitle,
    String? musicArtist,
    double musicVolume = 0.8,
    double musicStart = 0,
    bool clip = false,
    int clipSeconds = kPhotoClipSeconds,
    PostOptions options = const PostOptions(),
  }) async {
    // Look up the profile while the photo is uploading (saves a round trip).
    final meFuture = _me();
    meFuture.ignore(); // an error is reported below, once the upload is done
    final uploaded = await MediaServer.instance.uploadImage(
      image,
      onProgress: onProgress,
    );
    final me = await meFuture;
    final ref = _posts.doc();

    final batch = _db.batch();
    batch.set(ref, {
      'authorId': me.uid,
      'authorUsername': me.username,
      'authorPhotoUrl': me.photoUrl,
      // a photo clip is a photo that plays in Clips for a few seconds with its music
      'type': clip ? 'photoclip' : 'image',
      'caption': caption.trim(),
      'imageUrl': uploaded.ref,
      if (clip) 'videoDuration': clipSeconds,
      'musicId': ?musicId,
      'musicTitle': ?musicTitle,
      'musicArtist': ?musicArtist,
      if (musicId != null) 'musicVolume': musicVolume,
      if (musicId != null && musicStart > 0)
        'musicStart': double.parse(musicStart.toStringAsFixed(2)),
      if (width > 0 && height > 0) 'imageWidth': width,
      if (width > 0 && height > 0) 'imageHeight': height,
      'likeCount': 0,
      'commentCount': 0,
      ...options.toMap(),
      'authorPrivate': me.isPrivate,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(_db.collection('users').doc(me.uid), {
      'postsCount': FieldValue.increment(1),
    });
    await batch.commit();
    return uploaded.ref;
  }

  /// A post with several photos and videos (at least one photo), swiped sideways. [items]
  /// are already uploaded. It is stored as a normal 'image' post (so older versions of the app
  /// still show its first photo) plus a `media` list.
  Future<void> createCarouselPost({
    required List<PostItem> items,
    required String caption,
    String? musicId,
    String? musicTitle,
    String? musicArtist,
    double musicVolume = 0.8,
    double musicStart = 0,
    bool keepSound = true,
    PostOptions options = const PostOptions(),
  }) async {
    final photos = items.where((i) => !i.video).toList();
    if (items.length < 2 || items.length > kMaxPostItems || photos.isEmpty) {
      throw ArgumentError(
        'A carousel needs 2-$kMaxPostItems items with a photo.',
      );
    }
    final me = await _me();
    final ref = _posts.doc();
    final first = photos.first;
    final batch = _db.batch();
    batch.set(ref, {
      'authorId': me.uid,
      'authorUsername': me.username,
      'authorPhotoUrl': me.photoUrl,
      'type': 'image',
      'caption': caption.trim(),
      'imageUrl': first.ref,
      if (first.width > 0 && first.height > 0) 'imageWidth': first.width,
      if (first.width > 0 && first.height > 0) 'imageHeight': first.height,
      'media': [for (final i in items) i.toMap()],
      'musicId': ?musicId,
      'musicTitle': ?musicTitle,
      'musicArtist': ?musicArtist,
      if (musicId != null) 'musicVolume': musicVolume,
      if (musicId != null && musicStart > 0)
        'musicStart': double.parse(musicStart.toStringAsFixed(2)),
      if (musicId != null) 'keepSound': keepSound,
      'likeCount': 0,
      'commentCount': 0,
      ...options.toMap(),
      'authorPrivate': me.isPrivate,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(_db.collection('users').doc(me.uid), {
      'postsCount': FieldValue.increment(1),
    });
    await batch.commit();
  }

  /// [media] comes from MediaServer.uploadVideo.
  Future<void> createVideoPost({
    required UploadedMedia media,
    required String caption,
    required int duration,
    required int width,
    required int height,
    String? musicId,
    String? musicTitle,
    String? musicArtist,
    double musicVolume = 0.8,
    double musicStart = 0,
    bool keepSound = true,
    bool musicBaked = false,
    MediaFinish? finish,
    PostOptions options = const PostOptions(),
  }) async {
    final me = await _me();
    final ref = _posts.doc();
    final batch = _db.batch();
    batch.set(ref, {
      'authorId': me.uid,
      'authorUsername': me.username,
      'authorPhotoUrl': me.photoUrl,
      'type': 'video',
      if (finish != null && !finish.isEmpty) 'finish': finish.toMap(),
      'caption': caption.trim(),
      'videoUrl': media.ref,
      'thumbnailUrl': media.thumbRef,
      'videoDuration': duration,
      'videoWidth': width,
      'videoHeight': height,
      'musicId': ?musicId,
      'musicTitle': ?musicTitle,
      'musicArtist': ?musicArtist,
      if (musicId != null) 'musicVolume': musicVolume,
      if (musicId != null && musicStart > 0)
        'musicStart': double.parse(musicStart.toStringAsFixed(2)),
      if (musicId != null) 'keepSound': keepSound,
      if (musicId != null && musicBaked) 'musicBaked': true,
      'likeCount': 0,
      'commentCount': 0,
      ...options.toMap(),
      'authorPrivate': me.isPrivate,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(_db.collection('users').doc(me.uid), {
      'postsCount': FieldValue.increment(1),
    });
    await batch.commit();
  }

  /// Counts one view for [postId] by the signed-in person (once per person and post).
  Future<void> registerView(String postId) async {
    final me = _uid;
    final post = _posts.doc(postId);
    final seen = post.collection('views').doc(me);
    await _db.runTransaction((tx) async {
      if ((await tx.get(seen)).exists) return;
      tx.set(seen, {'at': FieldValue.serverTimestamp()});
      tx.update(post, {'viewCount': FieldValue.increment(1)});
    });
  }

  /// Counts one share (best effort: a failed count never blocks sharing).
  Future<void> registerShare(String postId) async {
    try {
      await _posts.doc(postId).update({'shareCount': FieldValue.increment(1)});
    } catch (_) {}
  }

  Future<void> deletePost(Post p) async {
    final batch = _db.batch();
    batch.delete(_posts.doc(p.id));
    batch.update(_db.collection('users').doc(p.authorId), {
      'postsCount': FieldValue.increment(-1),
    });
    await batch.commit();
    // Free the space in the bucket (best effort).
    await MediaServer.instance.deleteRefs([
      if (p.media.isNotEmpty)
        for (final m in p.media) ...[m.ref, m.thumbRef]
      else ...[p.isVideo ? p.videoRef : p.imageRef, p.thumbRef],
      deviceMusicRef(p.musicId), // a sound that came from the phone
    ]);
  }

  // ----------------------------------------------------------------- reposts

  CollectionReference<Map<String, dynamic>> _repostsOf(String uid) =>
      _db.collection('users').doc(uid).collection('reposts');

  Future<bool> isReposted(String postId) async =>
      (await _repostsOf(_uid).doc(postId).get()).exists;

  /// Puts a post on my profile (Reposts tab) or takes it off again.
  Future<void> setReposted(Post post, bool on) async {
    final ref = _repostsOf(_uid).doc(post.id);
    if (on) {
      await ref.set({
        'authorId': post.authorId,
        'repostedAt': FieldValue.serverTimestamp(),
      });
    } else {
      await ref.delete();
    }
    try {
      await _posts.doc(post.id).update({
        'repostCount': FieldValue.increment(on ? 1 : -1),
      });
    } catch (_) {
      // the counter is only a number; the repost itself is saved
    }
  }

  /// Newest-first posts [uid] reposted (max 30).
  Future<List<Post>> repostedPosts(String uid) async {
    final snap = await _repostsOf(
      uid,
    ).orderBy('repostedAt', descending: true).limit(30).get();
    return postsByIds([for (final d in snap.docs) d.id]);
  }

  // -------------------------------------------------------------------- pins

  /// Most posts and clips a person can pin to the top of their profile.
  static const int maxPins = 3;

  Future<List<Post>> pinnedPosts(String uid) async {
    final snap = await _posts
        .where('authorId', isEqualTo: uid)
        .where('pinned', isEqualTo: true)
        .limit(maxPins)
        .get();
    final list = [for (final d in snap.docs) Post.fromDoc(d)];
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  /// Pins or unpins one of my posts. Throws a readable message past [maxPins].
  Future<void> setPinned(Post post, bool pin) async {
    if (pin) {
      final now = await pinnedPosts(_uid);
      if (now.length >= maxPins && !now.any((p) => p.id == post.id)) {
        throw PinLimitException(
          'You can pin up to $maxPins posts. Unpin one first.',
        );
      }
    }
    await _posts.doc(post.id).update({'pinned': pin});
  }

  // ------------------------------------------------------------------- saved

  CollectionReference<Map<String, dynamic>> get _saved =>
      _db.collection('users').doc(_uid).collection('saved');

  Future<bool> isSaved(String postId) async =>
      (await _saved.doc(postId).get()).exists;

  Future<void> setSaved(String postId, bool saved) async {
    if (saved) {
      await _saved.doc(postId).set({'savedAt': FieldValue.serverTimestamp()});
    } else {
      await _saved.doc(postId).delete();
    }
  }

  /// Newest-first posts the current user saved (max 30).
  Future<List<Post>> savedPosts() async {
    final snap = await _saved
        .orderBy('savedAt', descending: true)
        .limit(30)
        .get();
    final ids = snap.docs.map((d) => d.id).toList();
    final byId = <String, Post>{};
    for (var i = 0; i < ids.length; i += 10) {
      final chunk = ids.sublist(i, i + 10 > ids.length ? ids.length : i + 10);
      final q = await _posts.where(FieldPath.documentId, whereIn: chunk).get();
      for (final d in q.docs) {
        byId[d.id] = Post.fromDoc(d);
      }
    }
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  /// The posts with these ids, in the same order (missing and hidden ones are left out).
  Future<List<Post>> postsByIds(List<String> ids) async {
    final byId = <String, Post>{};
    for (var i = 0; i < ids.length; i += 10) {
      final chunk = ids.sublist(i, i + 10 > ids.length ? ids.length : i + 10);
      final q = await _posts.where(FieldPath.documentId, whereIn: chunk).get();
      for (final d in q.docs) {
        byId[d.id] = Post.fromDoc(d);
      }
    }
    return [
      for (final id in ids)
        if (byId[id] != null && SafetyService.instance.canSee(byId[id]!))
          byId[id]!,
    ];
  }

  // ------------------------------------------------------------------- likes

  Future<bool> isLiked(String postId) async {
    final d = await _posts.doc(postId).collection('likes').doc(_uid).get();
    return d.exists;
  }

  Future<void> setLike(String postId, bool like) async {
    final postRef = _posts.doc(postId);
    final likeRef = postRef.collection('likes').doc(_uid);
    final batch = _db.batch();
    if (like) {
      batch.set(likeRef, {'createdAt': FieldValue.serverTimestamp()});
      batch.update(postRef, {'likeCount': FieldValue.increment(1)});
    } else {
      batch.delete(likeRef);
      batch.update(postRef, {'likeCount': FieldValue.increment(-1)});
    }
    await batch.commit();
    if (like) unawaited(_notifyLike(postId));
  }

  /// Tells the author of [postId] that someone liked it (one line in their activity).
  Future<void> _notifyLike(String postId) async {
    try {
      final d = await _posts.doc(postId).get();
      final m = d.data();
      if (m == null) return;
      final author = m['authorId'] is String ? m['authorId'] as String : '';
      if (author.isEmpty || author == _uid) return;
      await NotificationService.instance.notify(
        toUid: author,
        type: 'like',
        postId: postId,
        thumb: _thumbOf(m),
      );
    } catch (_) {
      // The activity line is optional.
    }
  }

  /// The small picture of a post, whatever its kind.
  static String _thumbOf(Map<String, dynamic> m) {
    for (final k in const ['thumbRef', 'imageRef', 'coverRef']) {
      final v = m[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return '';
  }

  // ---------------------------------------------------------------- comments

  Stream<List<Comment>> watchComments(String postId) => _posts
      .doc(postId)
      .collection('comments')
      .orderBy('createdAt', descending: true)
      .limit(200)
      .snapshots()
      .map((s) => s.docs.map(Comment.fromDoc).toList());

  /// A comment, a reply ([parentId] is the top-level comment), or one with a GIF, a photo
  /// (`m:` reference) or one of the author's own clips.
  Future<void> addComment(
    String postId,
    String text, {
    String parentId = '',
    String replyToUsername = '',
    String gifUrl = '',
    double gifAspect = 1,
    String imageRef = '',
    String clipId = '',
    String clipThumbRef = '',
  }) async {
    final me = await _me();
    final postRef = _posts.doc(postId);
    final batch = _db.batch();
    batch.set(postRef.collection('comments').doc(), {
      'authorId': me.uid,
      'authorUsername': me.username,
      'authorPhotoUrl': me.photoUrl,
      'text': text.trim(),
      'createdAt': FieldValue.serverTimestamp(),
      'likeCount': 0,
      if (parentId.isNotEmpty) 'parentId': parentId,
      if (parentId.isNotEmpty && replyToUsername.isNotEmpty)
        'replyToUsername': replyToUsername,
      if (gifUrl.isNotEmpty) 'gifUrl': gifUrl,
      if (gifUrl.isNotEmpty) 'gifAspect': gifAspect,
      if (imageRef.isNotEmpty) 'imageUrl': imageRef,
      if (clipId.isNotEmpty) 'clipId': clipId,
      if (clipThumbRef.isNotEmpty) 'clipThumb': clipThumbRef,
    });
    batch.update(postRef, {'commentCount': FieldValue.increment(1)});
    await batch.commit();
    unawaited(
      _notifyComment(
        postId: postId,
        text: text.trim(),
        parentId: parentId,
      ),
    );
  }

  /// Tells the author of the post, and the person being replied to.
  Future<void> _notifyComment({
    required String postId,
    required String text,
    required String parentId,
  }) async {
    try {
      final d = await _posts.doc(postId).get();
      final m = d.data();
      if (m == null) return;
      final author = m['authorId'] is String ? m['authorId'] as String : '';
      final thumb = _thumbOf(m);
      if (author.isNotEmpty && author != _uid) {
        await NotificationService.instance.notify(
          toUid: author,
          type: parentId.isEmpty ? 'comment' : 'reply',
          postId: postId,
          thumb: thumb,
          text: text,
        );
      }
      if (parentId.isNotEmpty) {
        final p = await _posts
            .doc(postId)
            .collection('comments')
            .doc(parentId)
            .get();
        final pm = p.data();
        if (pm == null) return;
        final who = pm['authorId'] is String ? pm['authorId'] as String : '';
        if (who.isEmpty || who == _uid || who == author) return;
        await NotificationService.instance.notify(
          toUid: who,
          type: 'reply',
          postId: postId,
          thumb: thumb,
          text: text,
        );
      }
    } catch (_) {
      // The activity line is optional.
    }
  }

  Future<void> editComment(String postId, String commentId, String text) {
    return _posts.doc(postId).collection('comments').doc(commentId).update({
      'text': text.trim(),
      'edited': true,
      'editedAt': FieldValue.serverTimestamp(),
    });
  }

  /// The owner of the post pins or unpins a comment (rules: only `pinned` may change).
  Future<void> setCommentPinned(String postId, String commentId, bool pinned) {
    return _posts.doc(postId).collection('comments').doc(commentId).update({
      'pinned': pinned,
    });
  }

  Future<void> deleteComment(String postId, String commentId) async {
    final postRef = _posts.doc(postId);
    final batch = _db.batch();
    batch.delete(postRef.collection('comments').doc(commentId));
    batch.update(postRef, {'commentCount': FieldValue.increment(-1)});
    await batch.commit();
  }

  CollectionReference<Map<String, dynamic>> _commentLikes(
    String postId,
    String commentId,
  ) => _posts
      .doc(postId)
      .collection('comments')
      .doc(commentId)
      .collection('likes');

  Future<bool> isCommentLiked(String postId, String commentId) async =>
      (await _commentLikes(postId, commentId).doc(_uid).get()).exists;

  Future<void> setCommentLike(
    String postId,
    String commentId,
    bool like,
  ) async {
    final ref = _posts.doc(postId).collection('comments').doc(commentId);
    final likeRef = ref.collection('likes').doc(_uid);
    final batch = _db.batch();
    if (like) {
      batch.set(likeRef, {'createdAt': FieldValue.serverTimestamp()});
      batch.update(ref, {'likeCount': FieldValue.increment(1)});
    } else {
      batch.delete(likeRef);
      batch.update(ref, {'likeCount': FieldValue.increment(-1)});
    }
    await batch.commit();
  }

  /// The signed-in user's own clips, newest first (for "Reply with a clip").
  Future<List<Post>> myClips({int limit = 40}) async {
    final snap = await userPostsQuery(_uid).limit(limit).get();
    return snap.docs.map(Post.fromDoc).where((p) => p.isClip).toList();
  }
}

/// Tried to pin more than [PostService.maxPins] posts.
class PinLimitException implements Exception {
  const PinLimitException(this.message);
  final String message;

  @override
  String toString() => message;
}
