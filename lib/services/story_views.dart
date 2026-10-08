import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/story.dart';
import '../models/story_view.dart';
import 'notification_service.dart';
import 'push_service.dart';
import 'user_service.dart';

/// Who watched my moments, how often and when; and the people whose views I want to hear
/// about (`storyAlerts/{me}.uids`, private: only I and the media signer read it).
///
/// Tests replace the backends; nothing here touches Firebase until it is used.
class StoryViews {
  StoryViews._();
  static final StoryViews instance = StoryViews._();

  /// Tests: replaces writing a view.
  Future<void> Function(Story story)? recordBackend;

  /// Tests: replaces reading the viewers of a moment.
  Future<List<StoryView>> Function(String storyId)? listBackend;

  /// Tests: replaces the alert list (read and write).
  Future<List<String>> Function()? alertsBackend;
  Future<void> Function(List<String> uids)? saveAlertsBackend;

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  String get _me => FirebaseAuth.instance.currentUser?.uid ?? '';

  /// Moments already counted during this visit of the viewer (going back and forth does not
  /// count again; opening the moments again later does: that is a rewatch).
  final Set<String> _countedNow = {};

  /// A new visit of the moments viewer starts.
  void newVisit() {
    _countedNow.clear();
    _recording.clear();
  }

  /// The writes of [record] still running, so a like waits until the view line exists.
  final Map<String, Future<void>> _recording = {};

  /// I watched [story]. Never for my own; never throws.
  Future<void> record(Story story) {
    if (!_countedNow.add(story.id)) {
      return _recording[story.id] ?? Future.value();
    }
    final f = _record(story);
    _recording[story.id] = f;
    return f;
  }

  Future<void> _record(Story story) async {
    try {
      final b = recordBackend;
      if (b != null) {
        await b(story);
        return;
      }
      final me = _me;
      if (me.isEmpty || story.authorId == me) return;
      final ref = _view(story, me);
      // read first: an update of a line that does not exist yet is refused by the rules
      // (it never says "not found"), so the first view was never written
      final snap = await ref.get();
      if (snap.exists) {
        await ref.update({
          'last': FieldValue.serverTimestamp(),
          'count': FieldValue.increment(1),
        });
        return;
      }
      final u = await UserService.instance.getUser(me);
      await ref.set({
        'username': u?.username ?? '',
        'photoUrl': u?.photoUrl ?? '',
        'first': FieldValue.serverTimestamp(),
        'last': FieldValue.serverTimestamp(),
        'count': 1,
      });
      // first view: the author hears about it if they asked for alerts about me
      PushService.instance.storyView(story.id, limited: story.limited);
    } catch (e) {
      debugPrint('story view not saved: $e');
    }
  }

  DocumentReference<Map<String, dynamic>> _view(Story story, String uid) => _db
      .collection(story.collection)
      .doc(story.id)
      .collection('views')
      .doc(uid);

  // ------------------------------------------------------------- moment likes

  /// Tests: replace reading and writing my like of a moment.
  Future<({bool liked, bool superHeart})> Function(Story story)? likeBackend;
  Future<void> Function(Story story, bool liked, bool superHeart)?
  setLikeBackend;

  /// Did I like [story] (and send it a super heart)?
  Future<({bool liked, bool superHeart})> likeOf(Story story) async {
    final b = likeBackend;
    if (b != null) return b(story);
    final me = _me;
    if (me.isEmpty || story.authorId == me) {
      return (liked: false, superHeart: false);
    }
    final d = (await _view(story, me).get()).data();
    return (liked: d?['liked'] == true, superHeart: d?['superHeart'] == true);
  }

  /// Likes / unlikes [story]; [superHeart] = a super heart (it also likes). The author gets
  /// a line in Notifications for a new like or super heart.
  Future<void> setLike(
    Story story, {
    required bool liked,
    bool superHeart = false,
    bool notify = true,
  }) async {
    final sup = liked && superHeart;
    final b = setLikeBackend;
    if (b != null) {
      await b(story, liked, sup);
      return;
    }
    final me = _me;
    if (me.isEmpty || story.authorId == me) return;
    await (_recording[story.id] ?? record(story)); // the line must exist first
    await _view(story, me).update({'liked': liked, 'superHeart': sup});
    if (liked && notify) {
      unawaited(
        NotificationService.instance.notify(
          toUid: story.authorId,
          type: sup ? 'story_super' : 'story_like',
        ),
      );
    }
  }

  /// Everyone who watched my moment, newest first.
  Future<List<StoryView>> viewers(
    String storyId, {
    String collection = 'stories',
  }) async {
    final b = listBackend;
    if (b != null) return StoryView.sorted(await b(storyId));
    final snap = await _db
        .collection(collection)
        .doc(storyId)
        .collection('views')
        .limit(1000)
        .get();
    return StoryView.sorted([
      for (final d in snap.docs) StoryView.fromMap(d.id, d.data()),
    ]);
  }

  // ------------------------------------------------------------- view alerts

  List<String>? _alerts;

  Future<List<String>> alerts() async {
    final cached = _alerts;
    if (cached != null) return cached;
    final b = alertsBackend;
    if (b != null) return _alerts = await b();
    final me = _me;
    if (me.isEmpty) return const [];
    final d = await _db.collection('storyAlerts').doc(me).get();
    final v = d.data()?['uids'];
    return _alerts = v is List ? [for (final x in v) '$x'] : <String>[];
  }

  Future<bool> hasAlert(String uid) async => (await alerts()).contains(uid);

  /// Turns "tell me when they watch my moments" on or off for [uid].
  Future<void> setAlert(String uid, bool on) async {
    final list = [...await alerts()]..remove(uid);
    if (on) list.add(uid);
    if (list.length > 100) list.removeRange(0, list.length - 100);
    _alerts = list;
    final b = saveAlertsBackend;
    if (b != null) {
      await b(list);
      return;
    }
    await _db.collection('storyAlerts').doc(_me).set({'uids': list});
  }

  /// After logging out / in.
  void forget() {
    _alerts = null;
    _countedNow.clear();
    _recording.clear();
  }
}
