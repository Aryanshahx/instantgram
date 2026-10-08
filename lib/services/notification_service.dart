import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/app_notification.dart';
import '../models/app_user.dart';
import 'user_service.dart';
import 'push_service.dart';

/// The activity of the signed-in account: likes, comments, replies and follows.
///
/// Everything is written to `notifications/{uid}/items` and read back by the bell in
/// Discover. There are no push notifications, so the list is up to date while the app is
/// open, and it is filled in from the moment this version is installed.
///
/// A notification that fails to be written never breaks the like, comment or follow that
/// caused it.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  // Lazy: the service must also work in tests, where there is no Firebase.
  FirebaseFirestore get _db => FirebaseFirestore.instance;

  /// Used by the tests instead of the signed-in account.
  String? testUid;

  String get _uid => testUid ?? FirebaseAuth.instance.currentUser!.uid;

  /// Tests replace these three to run without Firebase.
  Stream<List<AppNotification>> Function()? watchBackend;
  Future<void> Function(Map<String, dynamic> item)? sendBackend;
  Future<void> Function()? readBackend;

  AppUser? _me;

  /// The people I am, kept for the session (a notification only needs the name and photo).
  Future<AppUser?> _who() async {
    try {
      return _me ??= await UserService.instance.getUser(_uid);
    } catch (_) {
      return null;
    }
  }

  Stream<List<AppNotification>> watch() {
    final b = watchBackend;
    if (b != null) return b();
    return _db
        .collection('notifications')
        .doc(_uid)
        .collection('items')
        .orderBy('at', descending: true)
        .limit(60)
        .snapshots()
        .map(
          (s) => s.docs
              .map(AppNotification.fromDoc)
              .where((n) => n.type.isNotEmpty)
              .toList(),
        );
  }

  /// How many are new (the red dot on the bell).
  Stream<int> watchUnread() =>
      watch().map((l) => l.where((n) => !n.read).length);

  /// Writes one line of activity. [toUid] is who gets it; never the person who caused it.
  Future<void> notify({
    required String toUid,
    required String type,
    String postId = '',
    String thumb = '',
    String text = '',
  }) async {
    if (toUid.isEmpty || toUid == _uid) return;
    final me = await _who();
    final item = <String, dynamic>{
      'type': type,
      'actorId': _uid,
      'actorName': me?.username ?? '',
      'actorPhoto': me?.photoUrl ?? '',
      'postId': postId,
      'thumb': thumb,
      'text': text,
      'at': FieldValue.serverTimestamp(),
      'read': false,
    };
    final b = sendBackend;
    if (b != null) {
      await b(item);
      return;
    }
    try {
      final ref = await _db
          .collection('notifications')
          .doc(toUid)
          .collection('items')
          .add(item);
      PushService.instance.activity(toUid, ref.id);
    } catch (_) {
      // A missing activity line is not worth failing the like or the comment.
    }
  }

  /// Called when the activity screen opens: everything shown counts as seen.
  Future<void> markAllRead() async {
    final b = readBackend;
    if (b != null) {
      await b();
      return;
    }
    try {
      final snap = await _db
          .collection('notifications')
          .doc(_uid)
          .collection('items')
          .where('read', isEqualTo: false)
          .limit(60)
          .get();
      if (snap.docs.isEmpty) return;
      final batch = _db.batch();
      for (final d in snap.docs) {
        batch.update(d.reference, {'read': true});
      }
      await batch.commit();
    } catch (_) {
      // nothing to do: the list still shows
    }
  }

  /// Forgets the cached profile (tests, and after a profile edit).
  void clearCache() => _me = null;
}
