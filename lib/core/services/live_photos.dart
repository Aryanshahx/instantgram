import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// v0.0.2: everyone's CURRENT profile photo.
///
/// Comments, posts, chats, notifications ... save the photo the person had
/// back then. Avatars ask here by user id, so a new profile photo shows
/// everywhere. Photos are read in groups of 30 (one database read per
/// person) and kept for 15 minutes.
class LivePhotos {
  LivePhotos._();
  static final LivePhotos instance = LivePhotos._();

  /// Tests / no Firebase: never read the database.
  static bool disabled = false;

  static const Duration keep = Duration(minutes: 15);
  static const int group = 30;

  /// Changes when a photo arrives.
  final ValueNotifier<int> listenable = ValueNotifier(0);

  final Map<String, String> _urls = {};
  final Map<String, DateTime> _askedAt = {};
  final List<String> _queue = [];
  bool _scheduled = false;

  /// Reads the photos (tests can swap it). uid -> photoUrl.
  Future<Map<String, String>> Function(List<String> uids) reader = _read;

  /// The current photo of [uid] ('' = no photo), or null while unknown
  /// (then the saved [fallback] is shown and the photo is asked for).
  String? photoOf(String uid) {
    if (uid.isEmpty) return null;
    final asked = _askedAt[uid];
    if (asked == null || DateTime.now().difference(asked) > keep) _ask(uid);
    return _urls[uid];
  }

  /// [photoOf], else [fallback].
  String urlFor(String uid, String fallback) => photoOf(uid) ?? fallback;

  /// You changed your photo: show it at once everywhere.
  void put(String uid, String url) {
    if (uid.isEmpty) return;
    _urls[uid] = url;
    _askedAt[uid] = DateTime.now();
    listenable.value++;
  }

  /// Logout.
  void clear() {
    _urls.clear();
    _askedAt.clear();
    _queue.clear();
    listenable.value++;
  }

  static bool get _firebaseReady {
    try {
      return Firebase.apps.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  void _ask(String uid) {
    _askedAt[uid] = DateTime.now();
    if (disabled) return;
    if (identical(reader, _read) && !_firebaseReady) return;
    _queue.add(uid);
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(_flush);
  }

  Future<void> _flush() async {
    _scheduled = false;
    while (_queue.isNotEmpty) {
      final ids = _queue.take(group).toSet().toList();
      _queue.removeRange(0, _queue.length < group ? _queue.length : group);
      try {
        final got = await reader(ids);
        var changed = false;
        for (final id in ids) {
          final u = got[id];
          if (u == null) continue;
          if (_urls[id] != u) changed = true;
          _urls[id] = u;
        }
        if (changed) listenable.value++;
      } catch (e) {
        debugPrint('live photos: $e');
        for (final id in ids) {
          _askedAt.remove(id); // try again next time
        }
      }
    }
  }

  static Future<Map<String, String>> _read(List<String> uids) async {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .where(FieldPath.documentId, whereIn: uids)
        .get();
    return {
      for (final d in snap.docs)
        d.id: (d.data()['photoUrl'] is String)
            ? d.data()['photoUrl'] as String
            : '',
    };
  }
}
