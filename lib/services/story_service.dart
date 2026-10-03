import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../core/media_url.dart';
import '../models/story.dart';
import 'media_server.dart';
import 'user_service.dart';

class StoryService {
  StoryService._();
  static final StoryService instance = StoryService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _stories =>
      _db.collection('stories');
  String get _uid => FirebaseAuth.instance.currentUser!.uid;

  /// Stories from me + the people I follow that are still within 24 hours.
  Future<List<StoryGroup>> load() async {
    final following = await UserService.instance.followingIds();
    final allowed = {...following, _uid};

    final snap = await _stories
        .where('expiresAt', isGreaterThan: Timestamp.now())
        .orderBy('expiresAt')
        .limit(100)
        .get();

    final byAuthor = <String, List<Story>>{};
    for (final d in snap.docs) {
      final s = Story.fromDoc(d);
      if (!allowed.contains(s.authorId)) continue;
      if (isRemovedStorageRef(s.imageRef)) continue;
      byAuthor.putIfAbsent(s.authorId, () => []).add(s);
    }

    final groups = byAuthor.entries.map((e) {
      final list = [...e.value]
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return StoryGroup(
        authorId: e.key,
        username: list.last.username,
        photoUrl: list.last.photoUrl,
        stories: list,
      );
    }).toList();

    groups.sort((a, b) {
      if (a.authorId == _uid) return -1;
      if (b.authorId == _uid) return 1;
      return b.stories.last.createdAt.compareTo(a.stories.last.createdAt);
    });
    return groups;
  }

  Future<void> addStory(File image) async {
    final me = await UserService.instance.getUser(_uid);
    if (me == null) throw StateError('Profile not found');
    final ref = _stories.doc();
    final uploaded = await MediaServer.instance.uploadImage(image);
    await ref.set({
      'authorId': _uid,
      'authorUsername': me.username,
      'authorPhotoUrl': me.photoUrl,
      'imageUrl': uploaded.ref,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(
        DateTime.now().add(const Duration(hours: 24)),
      ),
    });
  }

  Future<void> deleteStory(Story s) async {
    await _stories.doc(s.id).delete();
    await MediaServer.instance.deleteQuietly(s.imageRef);
  }
}
