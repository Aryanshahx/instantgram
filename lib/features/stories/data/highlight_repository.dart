import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../shared/models/post.dart';
import '../../profile/data/user_repository.dart';

/// v0.15: a highlight = moments you keep on your profile (after 24 h too).
/// Saved in `users/{uid}/highlights/{id}` with a copy of every moment.
class Highlight {
  const Highlight({
    required this.id,
    required this.ownerUid,
    required this.title,
    required this.coverUrl,
    required this.username,
    required this.photoUrl,
    required this.items,
    required this.createdAt,
  });

  static const int maxItems = 100;
  static const int maxTitle = 30;

  final String id;
  final String ownerUid;
  final String title;
  final String coverUrl;
  final String username;
  final String photoUrl;
  final List<Story> items;
  final DateTime createdAt;

  List<String> get storyIds => [for (final s in items) s.id];

  /// For the moment viewer.
  StoryGroup get group => StoryGroup(ownerUid, items);

  /// Empty name = "Highlights"; max [maxTitle] letters.
  static String cleanTitle(String t) {
    final s = t.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (s.isEmpty) return 'Highlights';
    return s.length > maxTitle ? s.substring(0, maxTitle).trim() : s;
  }

  /// Cover picture: [preferred] if it is one of the photos, else the first
  /// photo, else '' (only videos: an icon is shown).
  static String coverOf(List<Story> items, {String preferred = ''}) {
    final photos = [
      for (final s in items)
        if (!s.isVideo && s.mediaUrl.isNotEmpty) s.mediaUrl,
    ];
    if (preferred.isNotEmpty && photos.contains(preferred)) return preferred;
    return photos.isEmpty ? '' : photos.first;
  }

  /// Oldest first (like moments), no doubles, max [maxItems].
  static List<Story> cleanItems(List<Story> items) {
    final seen = <String>{};
    final out = [
      for (final s in items)
        if (s.mediaUrl.isNotEmpty && seen.add(s.id)) s,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out.length > maxItems ? out.sublist(out.length - maxItems) : out;
  }

  static Map<String, dynamic> toMap({
    required String title,
    required List<Story> items,
    required String cover,
    required String username,
    required String photoUrl,
  }) {
    final list = cleanItems(items);
    return {
      'title': cleanTitle(title),
      'coverUrl': coverOf(list, preferred: cover),
      'username': username,
      'photoUrl': photoUrl,
      'storyIds': [for (final s in list) s.id],
      'items': [for (final s in list) s.toHighlightItem()],
    };
  }

  factory Highlight.fromMap(String id, String owner, Map<String, dynamic> m) {
    String s(Object? v) => v is String ? v : '';
    final username = s(m['username']);
    final photo = s(m['photoUrl']);
    final items = <Story>[];
    if (m['items'] is List) {
      for (final x in m['items'] as List) {
        if (x is! Map) continue;
        final map = Map<String, dynamic>.from(x);
        final story = Story.fromMap(s(map['id']), {
          ...map,
          'authorId': owner,
          'authorUsername': username,
          'authorPhotoUrl': photo,
        });
        if (story.mediaUrl.isNotEmpty) items.add(story);
      }
    }
    final created = m['createdAt'];
    return Highlight(
      id: id,
      ownerUid: owner,
      title: cleanTitle(s(m['title'])),
      coverUrl: s(m['coverUrl']),
      username: username,
      photoUrl: photo,
      items: items,
      createdAt: created is Timestamp ? created.toDate() : DateTime.now(),
    );
  }
}

class HighlightRepository {
  HighlightRepository._();
  static final HighlightRepository instance = HighlightRepository._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> _col(String uid) =>
      _db.collection('users').doc(uid).collection('highlights');

  /// Highlights of [uid], oldest first (like Instagram).
  Stream<List<Highlight>> watch(String uid) =>
      _col(uid)
          .orderBy('createdAt')
          .limit(60)
          .snapshots()
          .map(
            (s) =>
                [for (final d in s.docs) Highlight.fromMap(d.id, uid, d.data())]
                    .where((h) => h.items.isNotEmpty)
                    .toList(),
          );

  /// All your moments (also the old ones), newest first.
  Future<List<Story>> myMoments() async {
    final uid = UserRepository.instance.myUid;
    final snap = await _db
        .collection('stories')
        .where('authorId', isEqualTo: uid)
        .limit(300)
        .get();
    final list = snap.docs.map(Story.fromDoc).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Future<void> create(
    String title,
    List<Story> items, {
    String cover = '',
  }) async {
    final me = await UserRepository.instance.me();
    await _col(me.uid).add({
      ...Highlight.toMap(
        title: title,
        items: items,
        cover: cover,
        username: me.username,
        photoUrl: me.photoUrl,
      ),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> update(
    Highlight h,
    String title,
    List<Story> items, {
    String cover = '',
  }) async {
    final me = await UserRepository.instance.me();
    await _col(me.uid).doc(h.id).update({
      ...Highlight.toMap(
        title: title,
        items: items,
        cover: cover,
        username: me.username,
        photoUrl: me.photoUrl,
      ),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// v0.16: a new id for a highlight made while sharing (works without
  /// Firebase too: tests).
  String newIdSafe() {
    try {
      return _col(UserRepository.instance.myUid).doc().id;
    } catch (_) {
      const abc =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
      final r = math.Random.secure();
      return List.generate(20, (_) => abc[r.nextInt(abc.length)]).join();
    }
  }

  /// v0.16: adds just-uploaded moments to highlight [id] (made with
  /// [title] when it does not exist yet). Safe to call again.
  Future<void> addUploaded(String id, String title, List<Story> items) async {
    final me = await UserRepository.instance.me();
    final ref = _col(me.uid).doc(id);
    final snap = await ref.get();
    if (!snap.exists) {
      await ref.set({
        ...Highlight.toMap(
          title: title,
          items: items,
          cover: '',
          username: me.username,
          photoUrl: me.photoUrl,
        ),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return;
    }
    final h = Highlight.fromMap(id, me.uid, snap.data() ?? const {});
    await ref.update({
      ...Highlight.toMap(
        title: h.title,
        items: [...h.items, ...items],
        cover: h.coverUrl,
        username: me.username,
        photoUrl: me.photoUrl,
      ),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> delete(Highlight h) =>
      _col(UserRepository.instance.myUid).doc(h.id).delete();

  /// True when one of your highlights keeps the moment [storyId].
  Future<bool> isInHighlight(String storyId) async {
    final s = await _col(UserRepository.instance.myUid)
        .where('storyIds', arrayContains: storyId)
        .limit(1)
        .get();
    return s.docs.isNotEmpty;
  }
}
