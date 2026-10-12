import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/services/media_service.dart';
import '../../../shared/models/post.dart';
import '../../../shared/models/user_profile.dart';
import '../../notifications/data/notification_repository.dart';

class UserRepository {
  UserRepository._();
  static final UserRepository instance = UserRepository._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _users =>
      _db.collection('users');

  String get myUid => FirebaseAuth.instance.currentUser!.uid;

  Stream<UserProfile?> watchUser(String uid) {
    return _users.doc(uid).snapshots().map((snap) {
      if (!snap.exists) return null;
      return UserProfile.fromDoc(snap);
    });
  }

  Future<UserProfile?> getUser(String uid) async {
    final snap = await _users.doc(uid).get();
    return snap.exists ? UserProfile.fromDoc(snap) : null;
  }

  /// Current user's profile (falls back to auth info).
  Future<UserProfile> me() async {
    final u = FirebaseAuth.instance.currentUser!;
    final p = await getUser(u.uid);
    return p ??
        UserProfile(
          uid: u.uid,
          name: u.displayName ?? '',
          username: (u.email ?? 'user').split('@').first,
          email: u.email ?? '',
        );
  }

  Future<List<UserProfile>> getUsers(List<String> uids) async {
    final out = <UserProfile>[];
    for (var i = 0; i < uids.length; i += 30) {
      final chunk = uids.sublist(i, i + 30 > uids.length ? uids.length : i + 30);
      final snap =
          await _users.where(FieldPath.documentId, whereIn: chunk).get();
      out.addAll(snap.docs.map(UserProfile.fromDoc));
    }
    // keep original order
    final byId = {for (final u in out) u.uid: u};
    return [for (final id in uids) if (byId[id] != null) byId[id]!];
  }

  /// Username prefix search.
  Future<List<UserProfile>> search(String query) async {
    final q = query.trim().toLowerCase().replaceFirst('@', '');
    if (q.isEmpty) return [];
    final snap = await _users
        .where('username', isGreaterThanOrEqualTo: q)
        .where('username', isLessThan: '$q\uf8ff')
        .limit(25)
        .get();
    return snap.docs.map(UserProfile.fromDoc).toList();
  }

  Future<void> updateProfile({
    required String name,
    required String bio,
    required String website,
  }) {
    var site = website.trim();
    if (site.isNotEmpty && !site.startsWith('http')) site = 'https://$site';
    return _users.doc(myUid).update({
      'name': name.trim(),
      'bio': bio.trim(),
      'website': site,
    });
  }

  /// Upload new profile photo, update profile + your posts.
  Future<void> changePhoto(File file, {ValueChanged<double>? onProgress}) async {
    final old = await me();
    final media = await MediaService.instance
        .upload(file, kind: MediaKind.avatar, onProgress: onProgress);
    await _users.doc(myUid).update({
      'photoUrl': media.url,
      'photoKey': media.key,
    });
    // refresh avatar on your recent posts
    final posts =
        await _db.collection('posts').where('authorId', isEqualTo: myUid).limit(400).get();
    if (posts.docs.isNotEmpty) {
      final batch = _db.batch();
      for (final d in posts.docs) {
        batch.update(d.reference, {'authorPhotoUrl': media.url});
      }
      await batch.commit();
    }
    if (old.photoKey.isNotEmpty) MediaService.instance.delete(old.photoKey);
  }

  Future<void> changeCover(File file, {ValueChanged<double>? onProgress}) async {
    final old = await me();
    final media = await MediaService.instance
        .upload(file, kind: MediaKind.cover, onProgress: onProgress);
    await _users.doc(myUid).update({
      'coverUrl': media.url,
      'coverKey': media.key,
    });
    if (old.coverKey.isNotEmpty) MediaService.instance.delete(old.coverKey);
  }

  // ---------------- Follow ----------------

  Stream<bool> isFollowing(String targetUid) => _users
      .doc(myUid)
      .collection('following')
      .doc(targetUid)
      .snapshots()
      .map((s) => s.exists);

  Stream<List<String>> followingIds(String uid) => _users
      .doc(uid)
      .collection('following')
      .limit(500)
      .snapshots()
      .map((s) => s.docs.map((d) => d.id).toList());

  Future<void> follow(UserProfile target) async {
    final me = await this.me();
    final batch = _db.batch();
    batch.set(_users.doc(target.uid).collection('followers').doc(me.uid), {
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.set(_users.doc(me.uid).collection('following').doc(target.uid), {
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(_users.doc(target.uid), {
      'followersCount': FieldValue.increment(1),
    });
    batch.update(_users.doc(me.uid), {
      'followingCount': FieldValue.increment(1),
    });
    NotificationRepository.instance.addToBatch(
      batch,
      toUid: target.uid,
      from: me,
      type: AppNotification.follow,
    );
    await batch.commit();
  }

  Future<void> unfollow(UserProfile target) async {
    final batch = _db.batch();
    batch.delete(_users.doc(target.uid).collection('followers').doc(myUid));
    batch.delete(_users.doc(myUid).collection('following').doc(target.uid));
    batch.update(_users.doc(target.uid), {
      'followersCount': FieldValue.increment(-1),
    });
    batch.update(_users.doc(myUid), {
      'followingCount': FieldValue.increment(-1),
    });
    await batch.commit();
  }

  /// Followers or following list.
  Future<List<UserProfile>> connections(String uid, {required bool followers}) async {
    final snap = await _users
        .doc(uid)
        .collection(followers ? 'followers' : 'following')
        .orderBy('createdAt', descending: true)
        .limit(300)
        .get();
    return getUsers(snap.docs.map((d) => d.id).toList());
  }
}
