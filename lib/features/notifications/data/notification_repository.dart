import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/services/api_client.dart';
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
  /// v0.12: returns a [Pending] push: call [Pending.send] after the batch
  /// is saved, so the person also gets a phone notification.
  Pending addToBatch(
    WriteBatch batch, {
    required String toUid,
    required UserProfile from,
    required String type,
    Post? post,
    String text = '',
    String? postId,
  }) {
    if (toUid == from.uid || toUid.isEmpty) return const Pending.none();
    final ref = _col(toUid).doc();
    batch.set(ref, {
      'type': type,
      'fromUid': from.uid,
      'fromUsername': from.username,
      'fromPhotoUrl': from.photoUrl,
      'postId': post?.id ?? postId ?? '',
      'postThumb': post?.coverUrl ?? '',
      'text': text.length > 120 ? '${text.substring(0, 120)}…' : text,
      'read': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return Pending(toUid, ref.id);
  }

  /// v0.12: asks our server to send the phone notification (never throws).
  Future<void> push(String toUid, String id) async {
    if (toUid.isEmpty || id.isEmpty) return;
    try {
      await ApiClient.instance.post('/api/activity-push', {
        'to': toUid,
        'id': id,
      });
    } catch (e) {
      debugPrint('activity push: $e');
    }
  }

  /// v0.12: one notification right away (not in a batch).
  Future<void> addNow({
    required String toUid,
    required UserProfile from,
    required String type,
    Post? post,
    String text = '',
    String? postId,
  }) async {
    final batch = _db.batch();
    final p = addToBatch(
      batch,
      toUid: toUid,
      from: from,
      type: type,
      post: post,
      text: text,
      postId: postId,
    );
    if (p.isNone) return;
    await batch.commit();
    p.send();
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

/// v0.12: a saved notification whose phone push is not sent yet.
class Pending {
  const Pending(this.toUid, this.id);
  const Pending.none() : toUid = '', id = '';

  final String toUid;
  final String id;

  bool get isNone => id.isEmpty;

  /// Sends the phone notification in the background.
  void send() {
    if (isNone) return;
    unawaited(NotificationRepository.instance.push(toUid, id));
  }
}
