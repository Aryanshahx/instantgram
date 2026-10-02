import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/app_user.dart';
import '../models/comment.dart';
import '../models/post.dart';
import '../models/video_link.dart';
import 'storage_service.dart';
import 'user_service.dart';

typedef PostQuery = Query<Map<String, dynamic>>;

class PostService {
  PostService._();
  static final PostService instance = PostService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _posts => _db.collection('posts');
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

  /// needs composite index: type ASC + createdAt DESC
  PostQuery videoQuery() => _posts
      .where('type', isEqualTo: 'video')
      .orderBy('createdAt', descending: true);

  Future<Post?> getPost(String id) async {
    final d = await _posts.doc(id).get();
    return d.exists ? Post.fromDoc(d) : null;
  }

  // ------------------------------------------------------------------ create

  Future<AppUser> _me() async {
    final me = await UserService.instance.getUser(_uid);
    if (me == null) throw StateError('Profile not found');
    return me;
  }

  Future<void> createImagePost({required File image, required String caption}) async {
    final me = await _me();
    final ref = _posts.doc();
    final path = 'posts/${me.uid}/${ref.id}.jpg';
    final url = await StorageService.uploadImage(path, image);

    final batch = _db.batch();
    batch.set(ref, {
      'authorId': me.uid,
      'authorUsername': me.username,
      'authorPhotoUrl': me.photoUrl,
      'type': 'image',
      'caption': caption.trim(),
      'imageUrl': url,
      'imagePath': path,
      'likeCount': 0,
      'commentCount': 0,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(_db.collection('users').doc(me.uid),
        {'postsCount': FieldValue.increment(1)});
    await batch.commit();
  }

  Future<void> createVideoPost({
    required ResolvedVideo video,
    required String caption,
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
      // Only TEXT is stored for videos: the link + a thumbnail URL.
      'videoUrl': video.link.url,
      'videoPlatform': video.link.platform.name,
      'videoId': video.link.id ?? '',
      'thumbnailUrl': video.thumbnailUrl,
      'likeCount': 0,
      'commentCount': 0,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(_db.collection('users').doc(me.uid),
        {'postsCount': FieldValue.increment(1)});
    await batch.commit();
  }

  Future<void> deletePost(Post p) async {
    final batch = _db.batch();
    batch.delete(_posts.doc(p.id));
    batch.update(_db.collection('users').doc(p.authorId),
        {'postsCount': FieldValue.increment(-1)});
    await batch.commit();
    await StorageService.deleteQuietly(p.imagePath);
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
