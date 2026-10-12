import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../../core/services/media_service.dart';
import '../../../shared/models/post.dart';
import '../../profile/data/user_repository.dart';

class StoryRepository {
  StoryRepository._();
  static final StoryRepository instance = StoryRepository._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _stories =>
      _db.collection('stories');

  Future<void> create(File file, {ValueChanged<double>? onProgress}) async {
    final me = await UserRepository.instance.me();
    final media = await MediaService.instance
        .upload(file, kind: MediaKind.story, onProgress: onProgress);
    await _stories.add({
      'authorId': me.uid,
      'authorUsername': me.username,
      'authorPhotoUrl': me.photoUrl,
      'mediaUrl': media.url,
      'mediaKey': media.key,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(
        DateTime.now().add(const Duration(hours: 24)),
      ),
    });
  }

  Future<void> delete(Story story) async {
    await _stories.doc(story.id).delete();
    MediaService.instance.delete(story.mediaKey);
  }

  /// Active (last 24h) stories grouped by user, oldest first inside a group.
  Stream<List<StoryGroup>> active() => _stories
      .where('expiresAt', isGreaterThan: Timestamp.now())
      .limit(300)
      .snapshots()
      .map((s) {
        final map = <String, List<Story>>{};
        for (final d in s.docs) {
          final st = Story.fromDoc(d);
          map.putIfAbsent(st.authorId, () => []).add(st);
        }
        final groups = map.entries.map((e) {
          e.value.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          return StoryGroup(e.key, e.value);
        }).toList();
        groups.sort((a, b) =>
            b.stories.last.createdAt.compareTo(a.stories.last.createdAt));
        return groups;
      });
}
