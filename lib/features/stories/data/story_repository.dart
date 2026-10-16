import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../../core/services/content_filter.dart';
import '../../../core/services/media_service.dart';
import '../../../shared/models/post.dart';
import '../../../shared/models/user_profile.dart';
import '../../notifications/data/notification_repository.dart';
import '../../profile/data/user_repository.dart';
import 'highlight_repository.dart';
import 'story_views.dart';

/// Max length of a video moment.
const int kMomentMaxMs = 60 * 1000;

class StoryRepository {
  StoryRepository._();
  static final StoryRepository instance = StoryRepository._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _stories =>
      _db.collection('stories');

  Map<String, dynamic> _base(UserProfile me, String audience) => {
    'authorId': me.uid,
    'authorUsername': me.username,
    'authorPhotoUrl': me.photoUrl,
    'audience': audience,
    // v0.18: Hyper Intelligence checks it (the server sets the result)
    'modState': 'pending',
    'createdAt': FieldValue.serverTimestamp(),
    'expiresAt': Timestamp.fromDate(
      DateTime.now().add(const Duration(hours: 24)),
    ),
  };

  /// Upload one photo or video moment.
  Future<void> create(
    File file, {
    bool isVideo = false,
    VideoEdits edits = const VideoEdits(),
    int durationMs = 0,
    String audience = Audience.everyone,
    ValueChanged<double>? onProgress,
  }) async {
    final me = await UserRepository.instance.me();
    final media = await MediaService.instance.upload(
      file,
      kind: MediaKind.story,
      onProgress: onProgress,
    );
    await _stories.add({
      ..._base(me, audience),
      'type': isVideo ? Story.video : Story.photo,
      'mediaUrl': media.url,
      'mediaKey': media.key,
      if (isVideo && durationMs > 0) 'durationMs': durationMs,
      if (isVideo) ...edits.toMap(),
    });
  }

  /// New moment id (chosen before upload: a retry never posts twice).
  String newId() => _stories.doc().id;

  /// Writes a moment whose file is already uploaded (v0.8 upload queue).
  Future<void> createUploaded({
    required String id,
    required UploadedMedia media,
    bool isVideo = false,
    VideoEdits edits = const VideoEdits(),
    int durationMs = 0,
    String audience = Audience.everyone,
    UploadedMedia? audio,
    String audioName = '',
  }) async {
    final me = await UserRepository.instance.me();
    final ref = _stories.doc(id);
    try {
      await ref.set({
        ..._base(me, audience),
        'type': isVideo ? Story.video : Story.photo,
        'mediaUrl': media.url,
        'mediaKey': media.key,
        if (isVideo && durationMs > 0) 'durationMs': durationMs,
        if (isVideo) ...edits.toMap(),
        // v0.16: music on the moment
        if (audio != null) ...{
          'audioUrl': audio.url,
          'audioKey': audio.key,
          'audioName': audioName,
        },
      });
    } catch (e) {
      final done = await ref
          .get()
          .then((d) => d.exists)
          .catchError((Object _) => false);
      if (!done) rethrow;
    }
  }

  /// A moment that re-uses a new post's media (no own file -> mediaKey '').
  void addSharedToBatch(
    WriteBatch batch, {
    required UserProfile me,
    required String url,
    required bool isVideo,
    required String postId,
    String audience = Audience.everyone,
    VideoEdits edits = const VideoEdits(),
    int durationMs = 0,
  }) {
    batch.set(_stories.doc(), {
      ..._base(me, audience),
      'type': isVideo ? Story.video : Story.photo,
      'mediaUrl': url,
      'mediaKey': '',
      'postId': postId,
      if (isVideo && durationMs > 0)
        'durationMs': durationMs.clamp(0, kMomentMaxMs),
      if (isVideo) ...edits.toMap(),
    });
  }

  Future<void> delete(Story story) async {
    await _stories.doc(story.id).delete();
    if (story.mediaKey.isEmpty) return;
    // v0.15: a moment kept in a highlight keeps its file
    final kept = await HighlightRepository.instance
        .isInHighlight(story.id)
        .catchError((Object _) => true);
    if (!kept) MediaService.instance.delete(story.mediaKey);
  }

  // ---------------------------------------------------------------- v0.15

  /// You watched [st] (again): +1 for you in its viewer list. Not for your
  /// own moments, and not for previews.
  Future<void> recordView(Story st) async {
    final uid = UserRepository.instance.myUid;
    if (st.authorId == uid || st.id.isEmpty) return;
    final me = await UserRepository.instance.me();
    await _stories.doc(st.id).collection('views').doc(uid).set({
      'uid': uid,
      'username': me.username,
      'photoUrl': me.photoUrl,
      'count': FieldValue.increment(1),
      'lastAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// v0.16: heart on someone's moment (your view doc must exist:
  /// [recordView] first). The owner gets "X liked your moment" once.
  Future<void> setLike(Story st, bool liked) async {
    final uid = UserRepository.instance.myUid;
    if (st.authorId == uid || st.id.isEmpty) return;
    await _stories.doc(st.id).collection('views').doc(uid).update({
      'liked': liked,
      'likedAt': FieldValue.serverTimestamp(),
    });
    if (!liked || !_likeSent.add(st.id)) return;
    try {
      final me = await UserRepository.instance.me();
      await NotificationRepository.instance.addNow(
        toUid: st.authorId,
        from: me,
        type: AppNotification.momentLike,
        postId: '',
        thumb: st.isVideo ? '' : st.mediaUrl,
      );
    } catch (e) {
      debugPrint('moment like notification: $e'); // the like is saved
    }
  }

  final Set<String> _likeSent = {};

  /// v0.16: did I like moment [storyId] before?
  Future<bool> myLike(String storyId) async {
    final uid = UserRepository.instance.myUid;
    final d = await _stories.doc(storyId).collection('views').doc(uid).get();
    return d.data()?['liked'] == true;
  }

  /// Who watched your moment [storyId] (only you can read it).
  Stream<List<StoryView>> views(String storyId) => _stories
      .doc(storyId)
      .collection('views')
      .limit(500)
      .snapshots()
      .map(
        (s) => StoryInsights.sorted([
          for (final d in s.docs) StoryView.fromMap(d.id, d.data()),
        ]),
      );

  /// Active (last 24h) moments grouped by user, oldest first inside a group.
  Stream<List<StoryGroup>> active() {
    final raw = _stories
        .where('expiresAt', isGreaterThan: Timestamp.now())
        .limit(300)
        .snapshots()
        .map((s) => s.docs.map(Story.fromDoc).toList());
    return ContentFilter.instance
        .watch<Story>(raw, ContentFilter.instance.canSeeStory)
        .map(groupStories);
  }
}

/// Groups moments by author (newest group first).
List<StoryGroup> groupStories(List<Story> stories) {
  final now = DateTime.now();
  final map = <String, List<Story>>{};
  for (final st in stories) {
    if (now.difference(st.createdAt) > const Duration(hours: 24)) continue;
    map.putIfAbsent(st.authorId, () => []).add(st);
  }
  final groups = map.entries.map((e) {
    e.value.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return StoryGroup(e.key, e.value);
  }).toList();
  groups.sort(
    (a, b) => b.stories.last.createdAt.compareTo(a.stories.last.createdAt),
  );
  return groups;
}
