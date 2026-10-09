import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../core/media_url.dart';
import '../models/audience.dart';
import '../models/highlight.dart';
import '../models/music.dart';
import '../models/story.dart';
import '../models/story_view.dart';
import 'mp4_faststart.dart';
import 'highlight_service.dart';
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

  /// Stories from me + the people I follow that have not expired (24 or 48 hours).
  Future<List<StoryGroup>> load() async {
    // both lookups run at the same time (they do not depend on each other)
    final results = await Future.wait<Object>([
      UserService.instance.followingIds(),
      _stories
          .where('expiresAt', isGreaterThan: Timestamp.now())
          .orderBy('expiresAt')
          .limit(100)
          .get(),
      _forMe(),
    ]);
    final following = results[0] as List<String>;
    final snap = results[1] as QuerySnapshot<Map<String, dynamic>>;
    final listOnly = results[2] as List<Story>;
    final allowed = {...following, _uid};

    final byAuthor = <String, List<Story>>{};
    for (final s in [...snap.docs.map(Story.fromDoc), ...listOnly]) {
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
    final me = _uid;
    groups.sort((a, b) => compareStoryGroups(a, b, me));
    return groups;
  }

  CollectionReference<Map<String, dynamic>> get _private =>
      _db.collection(kPrivateStories);

  /// Moments shared to an audience list I am on (and my own list moments). Expired ones
  /// stay stored (like public ones) so they can still be added to a highlight.
  Future<List<Story>> _forMe() async {
    try {
      final snap = await _private
          .where('audience', arrayContains: _uid)
          .limit(300)
          .get();
      final now = DateTime.now();
      final out = <Story>[];
      for (final d in snap.docs) {
        final exp = d.data()['expiresAt'];
        final s = Story.fromDoc(d, limited: true);
        if (exp is Timestamp && exp.toDate().isAfter(now)) out.add(s);
      }
      return out;
    } catch (_) {
      return const []; // the public moments still show
    }
  }

  /// The fields that say who a moment is for, and whether it is in the spotlight.
  Map<String, dynamic> _audienceFields(StoryAudience audience, bool spotlight) {
    final list = audience.list;
    return {
      if (spotlight) 'spotlight': true,
      if (list != null) 'audience': list.audienceWith(_uid),
      if (list != null) 'listName': list.name,
    };
  }

  CollectionReference<Map<String, dynamic>> _colFor(StoryAudience a) =>
      a.isEveryone ? _stories : _private;

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
    bool longer = false,
    StoryAudience audience = const StoryAudience.everyone(),
    bool spotlight = false,
    Map<String, Object> safety = const {},
    void Function(double progress)? onProgress,
  }) async {
    if ((image == null) == (video == null)) {
      throw ArgumentError('Give either an image or a video.');
    }
    final me = await UserService.instance.getUser(_uid);
    if (me == null) throw StateError('Profile not found');
    final ref = _colFor(audience).doc();
    final data = <String, dynamic>{
      ..._audienceFields(audience, spotlight),
      'authorId': _uid,
      'authorUsername': me.username,
      'authorPhotoUrl': me.photoUrl,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(storyExpiry(DateTime.now(), longer)),
      ...safety,
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
    final h = audience.highlight;
    if (h != null) {
      // only into the highlight: no moment in the bar
      await HighlightService.instance.add(
        h,
        HighlightItem(
          id: ref.id,
          imageRef: data['imageUrl'] as String? ?? '',
          videoRef: data['videoUrl'] as String? ?? '',
          thumbRef: data['thumbnailUrl'] as String? ?? '',
          duration: duration,
          overlays: overlays.take(20).toList(),
          musicId: musicId,
          musicVolume: musicVolume,
          keepSound: keepSound,
          createdAt: DateTime.now(),
          own: true,
        ),
      );
      return;
    }
    await ref.set(data);
    StoryRing.instance.add(_uid);
  }

  /// All my moments, also expired ones (newest first): to pick from for a highlight.
  Future<List<Story>> archive() async {
    final me = _uid;
    final r = await Future.wait([
      _stories.where('authorId', isEqualTo: me).limit(150).get(),
      _private.where('audience', arrayContains: me).limit(300).get(),
    ]);
    final all = <Story>[
      ...r[0].docs.map(Story.fromDoc),
      for (final d in r[1].docs)
        if (d.data()['authorId'] == me) Story.fromDoc(d, limited: true),
    ]..removeWhere((s) => !s.isVideo && s.imageRef.isEmpty);
    all.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return all;
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
    bool longer = false,
    StoryAudience audience = const StoryAudience.everyone(),
    bool spotlight = false,
    Map<String, Object> safety = const {},
  }) async {
    final me = await UserService.instance.getUser(_uid);
    if (me == null) throw StateError('Profile not found');
    await _colFor(audience).doc().set({
      ...safety,
      ..._audienceFields(audience, spotlight),
      'authorId': _uid,
      'authorUsername': me.username,
      'authorPhotoUrl': me.photoUrl,
      'createdAt': FieldValue.serverTimestamp(),
      'expiresAt': Timestamp.fromDate(storyExpiry(DateTime.now(), longer)),
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
    // the viewer list goes first (nobody could remove it afterwards)
    try {
      final views = await _db
          .collection(s.collection)
          .doc(s.id)
          .collection('views')
          .get();
      for (final d in views.docs) {
        d.reference.delete().ignore();
      }
    } catch (_) {
      // best effort
    }
    await _db.collection(s.collection).doc(s.id).delete();
    if (s.shared) return; // the post still uses these files
    // files a highlight still shows stay
    Set<String> keep;
    try {
      keep = await HighlightService.instance.refsInUse();
    } catch (_) {
      return; // unsure: keep the files
    }
    await MediaServer.instance.deleteRefs([
      for (final r in [
        s.isVideo ? s.videoRef : s.imageRef,
        if (s.isVideo) s.thumbRef,
      ])
        if (!keep.contains(r)) r,
      if (!keep.contains(deviceMusicRef(s.musicId))) deviceMusicRef(s.musicId),
    ]);
  }
}
