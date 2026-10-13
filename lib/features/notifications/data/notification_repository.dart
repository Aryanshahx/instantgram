import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../shared/models/post.dart';
import '../../../shared/models/user_profile.dart';

class NotificationRepository {
  NotificationRepository._();
  static final NotificationRepository instance = NotificationRepository._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  String get _me => FirebaseAuth.instance.currentUser!.uid;

  CollectionReference<Map<String, dynamic>> _col(String uid) =>
      _db.collection('users').doc(uid).collection('notifications');

  /// Adds a notification to [batch] (skipped when notifying yourself).
  void addToBatch(
    WriteBatch batch, {
    required String toUid,
    required UserProfile from,
    required String type,
    Post? post,
    String text = '',
  }) {
    if (toUid == from.uid) return;
    batch.set(_col(toUid).doc(), {
      'type': type,
      'fromUid': from.uid,
      'fromUsername': from.username,
      'fromPhotoUrl': from.photoUrl,
      'postId': post?.id ?? '',
      'postThumb': post?.coverUrl ?? '',
      'text': text.length > 120 ? '${text.substring(0, 120)}…' : text,
      'read': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Stream<List<AppNotification>> watchMine() =>
      _col(_me)
          .orderBy('createdAt', descending: true)
          .limit(60)
          .snapshots()
          .map((s) => s.docs.map(AppNotification.fromDoc).toList());

  Stream<bool> hasUnread() =>
      _col(_me)
          .where('read', isEqualTo: false)
          .limit(1)
          .snapshots()
          .map((s) => s.docs.isNotEmpty);

  Future<void> markAllRead() async {
    final unread = await _col(_me)
        .where('read', isEqualTo: false)
        .limit(200)
        .get();
    if (unread.docs.isEmpty) return;
    final batch = _db.batch();
    for (final d in unread.docs) {
      batch.update(d.reference, {'read': true});
    }
    await batch.commit();
  }
}
