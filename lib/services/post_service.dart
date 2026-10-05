import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/app_user.dart';
import '../models/comment.dart';
import '../models/post.dart';
import 'post_search.dart';
import 'media_server.dart';
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
    return filterPosts(_pool, query);
  }

  /// Popular hashtags among the newest posts.
  Future<List<String>> trending() async {
    await searchPosts(' '); // loads the pool
    return trendingTags(_pool);
  }

  // ------------------------------------------------------------------ create

  Future<AppUser> _me() async {
    final me = await UserService.instance.getUser(_uid);
    if (me == null) throw StateError('Profile not found');
    return me;
  }

  Future<void> createImagePost({
    required File image,
    required String caption,
    void Function(double progress)? onProgress,
    int width = 0,
    int height = 0,
    String? musicId,
    String? musicTitle,
    String? musicArtist,
    double musicVolume = 0.8,
    bool clip = false,
    int clipSeconds = kPhotoClipSeconds,
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
      if (width > 0 && height > 0) 'imageWidth': width,
      if (width > 0 && height > 0) 'imageHeight': height,
      'likeCount': 0,
      'commentCount': 0,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(_db.collection('users').doc(me.uid), {
      'postsCount': FieldValue.increment(1),
    });
    await batch.commit();
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
    bool keepSound = true,
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
      if (musicId != null) 'keepSound': keepSound,
      'likeCount': 0,
      'commentCount': 0,
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
    bool keepSound = true,
  }) async {
    final me = await _me();
    final ref = _posts.doc();
    final batch = _db.batch();
    batch.set(ref, {
      'authorId': me.uid,
      'authorUsername': me.username,
      'authorPhotoUrl': me.photoUrl,
      'type': 'video',
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
      if (musicId != null) 'keepSound': keepSound,
      'likeCount': 0,
      'commentCount': 0,
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
    ]);
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
  }

  // ---------------------------------------------------------------- comments

  Stream<List<Comment>> watchComments(String postId) => _posts
      .doc(postId)
      .collection('comments')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots()
      .map((s) => s.docs.map(Comment.fromDoc).toList());

  Future<void> addComment(String postId, String text) async {
    final me = await _me();
    final postRef = _posts.doc(postId);
    final batch = _db.batch();
    batch.set(postRef.collection('comments').doc(), {
      'authorId': me.uid,
      'authorUsername': me.username,
      'authorPhotoUrl': me.photoUrl,
      'text': text.trim(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(postRef, {'commentCount': FieldValue.increment(1)});
    await batch.commit();
  }

  Future<void> deleteComment(String postId, String commentId) async {
    final postRef = _posts.doc(postId);
    final batch = _db.batch();
    batch.delete(postRef.collection('comments').doc(commentId));
    batch.update(postRef, {'commentCount': FieldValue.increment(-1)});
    await batch.commit();
  }
}
