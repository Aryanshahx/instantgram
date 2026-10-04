import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/app_user.dart';
import '../core/errors.dart';
import 'media_server.dart';

class UserService {
  UserService._();
  static final UserService instance = UserService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _users =>
      _db.collection('users');

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
    final snap = await _users
        .orderBy('createdAt', descending: true)
        .limit(20)
        .get();
    return snap.docs.map(AppUser.fromDoc).where((u) => u.uid != myUid).toList();
  }

  // ---------------------------------------------------------------- follows

  Future<bool> isFollowing(String targetUid) async {
    final d = await _users
        .doc(myUid)
        .collection('following')
        .doc(targetUid)
        .get();
    return d.exists;
  }

  Future<void> follow(String targetUid) async {
    final me = myUid;
    if (me == targetUid) return;
    final batch = _db.batch();
    batch.set(_users.doc(me).collection('following').doc(targetUid), {
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.set(_users.doc(targetUid).collection('followers').doc(me), {
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(_users.doc(me), {'followingCount': FieldValue.increment(1)});
    batch.update(_users.doc(targetUid), {
      'followersCount': FieldValue.increment(1),
    });
    await batch.commit();
  }

  Future<void> unfollow(String targetUid) async {
    final me = myUid;
    final batch = _db.batch();
    batch.delete(_users.doc(me).collection('following').doc(targetUid));
    batch.delete(_users.doc(targetUid).collection('followers').doc(me));
    batch.update(_users.doc(me), {'followingCount': FieldValue.increment(-1)});
    batch.update(_users.doc(targetUid), {
      'followersCount': FieldValue.increment(-1),
    });
    await batch.commit();
  }

  /// ids of the people [uid] follows (max 100)
  Future<List<String>> followingIds([String? uid]) =>
      _subIds(uid ?? myUid, 'following');

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

  static final RegExp usernameRegex = RegExp(r'^[a-z0-9._]{3,20}$');

  /// Saves the edited profile. Every piece is optional:
  ///  * [newPhoto] / [removePhoto] change the profile picture
  ///  * [newBanner] / [removeBanner] change the cover picture
  ///  * [username] claims a new unique name (the old one is released)
  ///  * [links] replaces the links (max 3)
  Future<void> updateProfile({
    required String fullName,
    required String bio,
    File? newPhoto,
    bool removePhoto = false,
    File? newBanner,
    bool removeBanner = false,
    String? username,
    List<String>? links,
  }) async {
    final uid = myUid;
    final before = await getUser(uid);
    final data = <String, dynamic>{
      'fullName': fullName.trim(),
      'bio': bio.trim(),
    };
    if (links != null) data['links'] = links.take(3).toList();

    final oldRefs = <String?>[];
    if (newPhoto != null) {
      oldRefs.add(before?.photoUrl);
      data['photoUrl'] = (await MediaServer.instance.uploadImage(newPhoto)).ref;
    } else if (removePhoto) {
      oldRefs.add(before?.photoUrl);
      data['photoUrl'] = '';
    }
    if (newBanner != null) {
      oldRefs.add(before?.bannerUrl);
      data['bannerUrl'] = (await MediaServer.instance.uploadImage(
        newBanner,
      )).ref;
    } else if (removeBanner) {
      oldRefs.add(before?.bannerUrl);
      data['bannerUrl'] = '';
    }

    final wanted = username?.trim().toLowerCase();
    final rename =
        wanted != null && wanted.isNotEmpty && wanted != before?.username;
    if (rename) {
      if (!usernameRegex.hasMatch(wanted)) {
        throw const MediaException(
          'Username: 3-20 characters, only a-z, 0-9, dot and underscore.',
        );
      }
      final old = before?.username ?? '';
      // claim the new name, release the old one and save the profile in one go
      await _db.runTransaction((tx) async {
        final nameRef = _db.collection('usernames').doc(wanted);
        if ((await tx.get(nameRef)).exists) {
          throw const UsernameTakenException();
        }
        final oldRef = old.isEmpty
            ? null
            : _db.collection('usernames').doc(old);
        final oldSnap = oldRef == null ? null : await tx.get(oldRef);
        final email = FirebaseAuth.instance.currentUser?.email;
        tx.set(nameRef, {
          'uid': uid,
          if (email != null && email.isNotEmpty) 'email': email,
        });
        if (oldRef != null && (oldSnap?.exists ?? false)) tx.delete(oldRef);
        tx.update(_users.doc(uid), {...data, 'username': wanted});
      });
    } else {
      await _users.doc(uid).update(data);
    }

    // Keep the name and picture shown on the user's own posts up to date (best effort).
    final nameChanged = rename;
    final photoChanged = data.containsKey('photoUrl');
    if (nameChanged || photoChanged) {
      await _refreshPosts(
        uid,
        username: nameChanged ? wanted : null,
        photo: photoChanged ? data['photoUrl'] as String : null,
      );
    }
    for (final r in oldRefs) {
      await MediaServer.instance.deleteQuietly(r);
    }
  }

  Future<void> _refreshPosts(
    String uid, {
    String? username,
    String? photo,
  }) async {
    try {
      final snap = await _db
          .collection('posts')
          .where('authorId', isEqualTo: uid)
          .limit(400)
          .get();
      for (var i = 0; i < snap.docs.length; i += 400) {
        final batch = _db.batch();
        for (final d in snap.docs.skip(i).take(400)) {
          batch.update(d.reference, {
            if (username != null) 'authorUsername': username,
            if (photo != null) 'authorPhotoUrl': photo,
          });
        }
        await batch.commit();
      }
    } catch (_) {
      // old posts keep the old name until the next edit; nothing else depends on it
    }
  }
}
