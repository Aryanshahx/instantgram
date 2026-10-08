import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/story.dart';
import '../models/story_view.dart';
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
  void newVisit() => _countedNow.clear();

  /// I watched [story]. Never for my own; never throws.
  Future<void> record(Story story) async {
    if (!_countedNow.add(story.id)) return;
    try {
      final b = recordBackend;
      if (b != null) {
        await b(story);
        return;
      }
      final me = _me;
      if (me.isEmpty || story.authorId == me) return;
      final ref = _db
          .collection('stories')
          .doc(story.id)
          .collection('views')
          .doc(me);
      try {
        await ref.update({
          'last': FieldValue.serverTimestamp(),
          'count': FieldValue.increment(1),
        });
      } on FirebaseException catch (e) {
        if (e.code != 'not-found') rethrow;
        final u = await UserService.instance.getUser(me);
        await ref.set({
          'username': u?.username ?? '',
          'photoUrl': u?.photoUrl ?? '',
          'first': FieldValue.serverTimestamp(),
          'last': FieldValue.serverTimestamp(),
          'count': 1,
        });
        // first view: the author hears about it if they asked for alerts about me
        PushService.instance.storyView(story.id);
      }
    } catch (_) {
      // a missing view is not worth an error on screen
    }
  }

  /// Everyone who watched my moment, newest first.
  Future<List<StoryView>> viewers(String storyId) async {
    final b = listBackend;
    if (b != null) return StoryView.sorted(await b(storyId));
    final snap = await _db
        .collection('stories')
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
  }
}
