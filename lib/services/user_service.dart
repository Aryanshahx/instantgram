import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/app_user.dart';
import 'storage_service.dart';

class UserService {
  UserService._();
  static final UserService instance = UserService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _users => _db.collection('users');

  String get myUid => FirebaseAuth.instance.currentUser!.uid;

  Stream<AppUser?> watchUser(String uid) => _users
      .doc(uid)
      .snapshots()
      .map((d) => d.exists ? AppUser.fromDoc(d) : null);

  Future<AppUser?> getUser(String uid) async {
    final d = await _users.doc(uid).get();
    return d.exists ? AppUser.fromDoc(d) : null;
  }

  Future<List<AppUser>> getUsers(Iterable<String> ids) async {
    final list = await Future.wait(ids.map(getUser));
    return list.whereType<AppUser>().toList();
  }

  Future<List<AppUser>> searchUsers(String query) async {
    final p = query.trim().toLowerCase();
    if (p.isEmpty) return [];
    final snap = await _users
        .orderBy('username')
        .startAt([p])
        .endAt(['$p\uf8ff'])
        .limit(20)
        .get();
    return snap.docs.map(AppUser.fromDoc).toList();
  }

  Future<List<AppUser>> suggestedUsers() async {
    final snap =
        await _users.orderBy('createdAt', descending: true).limit(20).get();
    return snap.docs.map(AppUser.fromDoc).where((u) => u.uid != myUid).toList();
  }

  // ---------------------------------------------------------------- follows

  Future<bool> isFollowing(String targetUid) async {
    final d = await _users.doc(myUid).collection('following').doc(targetUid).get();
    return d.exists;
  }

  Future<void> follow(String targetUid) async {
    final me = myUid;
    if (me == targetUid) return;
    final batch = _db.batch();
    batch.set(_users.doc(me).collection('following').doc(targetUid),
        {'createdAt': FieldValue.serverTimestamp()});
    batch.set(_users.doc(targetUid).collection('followers').doc(me),
        {'createdAt': FieldValue.serverTimestamp()});
    batch.update(_users.doc(me), {'followingCount': FieldValue.increment(1)});
    batch.update(
        _users.doc(targetUid), {'followersCount': FieldValue.increment(1)});
    await batch.commit();
  }

  Future<void> unfollow(String targetUid) async {
    final me = myUid;
    final batch = _db.batch();
    batch.delete(_users.doc(me).collection('following').doc(targetUid));
    batch.delete(_users.doc(targetUid).collection('followers').doc(me));
    batch.update(_users.doc(me), {'followingCount': FieldValue.increment(-1)});
    batch.update(
        _users.doc(targetUid), {'followersCount': FieldValue.increment(-1)});
    await batch.commit();
  }

  /// ids of the people [uid] follows (max 100)
  Future<List<String>> followingIds([String? uid]) => _subIds(uid ?? myUid, 'following');

  Future<List<String>> followerIds(String uid) => _subIds(uid, 'followers');

  Future<List<String>> _subIds(String uid, String sub) async {
    final snap = await _users
        .doc(uid)
        .collection(sub)
        .orderBy('createdAt', descending: true)
        .limit(100)
        .get();
    return snap.docs.map((d) => d.id).toList();
  }

  // ---------------------------------------------------------------- profile

  Future<void> updateProfile({
    required String fullName,
    required String bio,
    File? newPhoto,
  }) async {
    final uid = myUid;
    final data = <String, dynamic>{
      'fullName': fullName.trim(),
      'bio': bio.trim(),
    };
    String? oldPath;
    if (newPhoto != null) {
      oldPath = (await getUser(uid))?.photoPath;
      final path = 'avatars/$uid/${DateTime.now().millisecondsSinceEpoch}.jpg';
      data['photoUrl'] = await StorageService.uploadImage(path, newPhoto);
      data['photoPath'] = path;
    }
    await _users.doc(uid).update(data);
    await StorageService.deleteQuietly(oldPath);
  }
}
