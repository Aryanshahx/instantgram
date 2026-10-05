import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../core/media_url.dart';
import '../models/story.dart';
import 'mp4_faststart.dart';
import 'media_server.dart';
import 'story_ring.dart';
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
    // both lookups run at the same time (they do not depend on each other)
    final results = await Future.wait<Object>([
      UserService.instance.followingIds(),
      _stories
          .where('expiresAt', isGreaterThan: Timestamp.now())
          .orderBy('expiresAt')
          .limit(100)
          .get(),
    ]);
    final following = results[0] as List<String>;
    final snap = results[1] as QuerySnapshot<Map<String, dynamic>>;
    final allowed = {...following, _uid};

    final byAuthor = <String, List<Story>>{};
    for (final d in snap.docs) {
      final s = Story.fromDoc(d);
      if (!allowed.contains(s.authorId)) continue;
      if (isRemovedStorageRef(s.imageRef)) continue;
      if (!s.isVideo && s.imageRef.isEmpty) continue;
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

    StoryRing.instance.setAll(byAuthor.keys);
    groups.sort((a, b) {
      if (a.authorId == _uid) return -1;
      if (b.authorId == _uid) return 1;
      return b.stories.last.createdAt.compareTo(a.stories.last.createdAt);
    });
    return groups;
  }

  /// Shares a moment: a photo ([image]) or a video ([video] with its cover [thumb]), with
  /// the texts and stickers placed on it and optional music.
  Future<void> addStory({
    File? image,
    File? video,
    File? thumb,
    int duration = 0,
    List<StoryOverlay> overlays = const [],
    String musicId = '',
    String musicTitle = '',
    String musicArtist = '',
    double musicVolume = 0.8,
    bool keepSound = true,
    void Function(double progress)? onProgress,
  }) async {
    if ((image == null) == (video == null)) {
      throw ArgumentError('Give either an image or a video.');
    }
    final me = await UserService.instance.getUser(_uid);
    if (me == null) throw StateError('Profile not found');
    final ref = _stories.doc();
    final data = <String, dynamic>{
      'authorId': _uid,
      'authorUsername': me.username,
      'authorPhotoUrl': me.photoUrl,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(
        DateTime.now().add(const Duration(hours: 24)),
      ),
      if (overlays.isNotEmpty)
        'overlays': [for (final o in overlays.take(20)) o.toMap()],
      if (musicId.isNotEmpty) ...{
        'musicId': musicId,
        if (musicTitle.isNotEmpty) 'musicTitle': musicTitle,
        if (musicArtist.isNotEmpty) 'musicArtist': musicArtist,
        'musicVolume': musicVolume,
      },
    };
    if (video != null) {
      // the video's index goes to the front so the moment starts playing at once
      // (nothing is re-encoded)
      final fast = await Mp4FastStart.run(video);
      final UploadedMedia up;
      try {
        up = await MediaServer.instance.uploadVideo(
          file: fast,
          thumb: thumb,
          onProgress: onProgress,
        );
      } finally {
        if (fast.path != video.path) fast.delete().ignore();
      }
      data['videoUrl'] = up.ref;
      data['thumbnailUrl'] = up.thumbRef;
      data['imageUrl'] = '';
      data['duration'] = duration;
      data['keepSound'] = keepSound;
    } else {
      final up = await MediaServer.instance.uploadImage(
        image!,
        onProgress: onProgress,
      );
      data['imageUrl'] = up.ref;
    }
    await ref.set(data);
    StoryRing.instance.add(_uid);
  }

  /// Puts an already uploaded post photo or clip in my moments (nothing is uploaded again).
  Future<void> addStoryFromRefs({
    String imageRef = '',
    String videoRef = '',
    String thumbRef = '',
    int duration = 0,
    String musicId = '',
    String musicTitle = '',
    String musicArtist = '',
    double musicVolume = 0.8,
    bool keepSound = true,
  }) async {
    final me = await UserService.instance.getUser(_uid);
    if (me == null) throw StateError('Profile not found');
    await _stories.doc().set({
      'authorId': _uid,
      'authorUsername': me.username,
      'authorPhotoUrl': me.photoUrl,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(
        DateTime.now().add(const Duration(hours: 24)),
      ),
      'sharedFromPost': true,
      'imageUrl': videoRef.isEmpty ? imageRef : '',
      if (videoRef.isNotEmpty) ...{
        'videoUrl': videoRef,
        'thumbnailUrl': thumbRef,
        'duration': duration,
        'keepSound': keepSound,
      },
      if (musicId.isNotEmpty) ...{
        'musicId': musicId,
        if (musicTitle.isNotEmpty) 'musicTitle': musicTitle,
        if (musicArtist.isNotEmpty) 'musicArtist': musicArtist,
        'musicVolume': musicVolume,
      },
    });
    StoryRing.instance.add(_uid);
  }

  Future<void> deleteStory(Story s) async {
    await _stories.doc(s.id).delete();
    if (s.shared) return; // the post still uses these files
    await MediaServer.instance.deleteQuietly(
      s.isVideo ? s.videoRef : s.imageRef,
      s.isVideo ? s.thumbRef : null,
    );
  }
}
