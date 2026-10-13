import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/services/content_filter.dart';
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

  /// Profiles for many uids (asks 30 at a time, in parallel).
  Future<List<UserProfile>> usersByIds(List<String> uids) async {
    final ids = uids.toSet().toList();
    if (ids.isEmpty) return const [];
    final parts = <Future<QuerySnapshot<Map<String, dynamic>>>>[];
    for (var i = 0; i < ids.length; i += 30) {
      final chunk = ids.sublist(i, i + 30 > ids.length ? ids.length : i + 30);
      parts.add(_users.where(FieldPath.documentId, whereIn: chunk).get());
    }
    final snaps = await Future.wait(parts);
    final byId = {
      for (final s in snaps)
        for (final d in s.docs) d.id: UserProfile.fromDoc(d),
    };
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  UserProfile? _meCache;
  DateTime _meCacheAt = DateTime(2000);

  /// Fast version of [me] for likes / reposts / comments:
  /// uses a copy kept in memory (refreshed every 5 minutes).
  Future<UserProfile> meCached() async {
    final c = _meCache;
    if (c != null &&
        c.uid == FirebaseAuth.instance.currentUser?.uid &&
        DateTime.now().difference(_meCacheAt).inMinutes < 5) {
      return c;
    }
    return me();
  }

  void _clearMeCache() => _meCache = null;

  /// Current user's profile (falls back to auth info).
  Future<UserProfile> me() async {
    final u = FirebaseAuth.instance.currentUser!;
    final p = await getUser(u.uid);
    if (p != null) {
      _meCache = p;
      _meCacheAt = DateTime.now();
    }
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
      final chunk = uids.sublist(
        i,
        i + 30 > uids.length ? uids.length : i + 30,
      );
      final snap = await _users
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      out.addAll(snap.docs.map(UserProfile.fromDoc));
    }
    // keep original order
    final byId = {for (final u in out) u.uid: u};
    return [
      for (final id in uids)
        if (byId[id] != null) byId[id]!,
    ];
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
    return snap.docs
        .map(UserProfile.fromDoc)
        .where((u) => !ContentFilter.instance.isBlocked(u.uid))
        .toList();
  }

  Future<void> updateProfile({
    required String name,
    required String bio,
    String? website,
    List<ProfileLink>? links,
  }) {
    final data = <String, dynamic>{'name': name.trim(), 'bio': bio.trim()};
    if (links != null) {
      final clean = links
          .where((l) => l.url.isNotEmpty)
          .take(UserProfile.maxLinks)
          .toList();
      data['links'] = clean.map((l) => l.toMap()).toList();
      // older app versions show one website: the first link
      data['website'] = clean.isEmpty ? '' : clean.first.url;
    } else if (website != null) {
      var site = website.trim();
      if (site.isNotEmpty && !site.startsWith('http')) site = 'https://$site';
      data['website'] = site;
    }
    _clearMeCache();
    return _users.doc(myUid).update(data);
  }

  /// Why [name] can't be a username ('' = fine). Lower case is expected.
  static String usernameProblem(String name) {
    if (name.length < 3) return 'At least 3 characters';
    if (name.length > 30) return 'At most 30 characters';
    if (!RegExp(r'^[a-z0-9._]+$').hasMatch(name)) {
      return 'Only letters, numbers, . and _';
    }
    return '';
  }

  /// True when nobody (else) has [name].
  Future<bool> usernameFree(String name) async {
    final snap = await _db.collection('usernames').doc(name).get();
    return !snap.exists || snap.data()?['uid'] == myUid;
  }

  /// Changes your username (must be unique). Frees the old one and
  /// updates the name on your posts.
  Future<void> changeUsername(String newName) async {
    final name = newName.trim().toLowerCase();
    final problem = usernameProblem(name);
    if (problem.isNotEmpty) throw StateError(problem);
    final uid = myUid;
    final userRef = _users.doc(uid);
    final newRef = _db.collection('usernames').doc(name);
    await _db.runTransaction((tx) async {
      final user = await tx.get(userRef);
      final old = (user.data()?['username'] as String?) ?? '';
      if (old == name) return;
      final taken = await tx.get(newRef);
      if (taken.exists && taken.data()?['uid'] != uid) {
        throw StateError('That username is taken');
      }
      final oldRef = _db.collection('usernames').doc(old.isEmpty ? '-' : old);
      final oldSnap = old.isEmpty ? null : await tx.get(oldRef);
      final email =
          (oldSnap?.data()?['email'] as String?) ??
          FirebaseAuth.instance.currentUser?.email ??
          '';
      if (!taken.exists) tx.set(newRef, {'uid': uid, 'email': email});
      if (oldSnap != null && oldSnap.exists && oldSnap.data()?['uid'] == uid) {
        tx.delete(oldRef);
      }
      tx.update(userRef, {'username': name});
    });
    _clearMeCache();
    // show the new name on your posts
    try {
      final posts = await _db
          .collection('posts')
          .where('authorId', isEqualTo: uid)
          .limit(400)
          .get();
      if (posts.docs.isNotEmpty) {
        final batch = _db.batch();
        for (final d in posts.docs) {
          batch.update(d.reference, {'authorUsername': name});
        }
        await batch.commit();
      }
    } catch (e) {
      debugPrint('username on posts: $e');
    }
  }

  /// Finds a user by username (for profile links and QR codes).
  Future<UserProfile?> userByUsername(String name) async {
    final n = name.trim().toLowerCase().replaceFirst('@', '');
    if (usernameProblem(n).isNotEmpty) return null;
    final snap = await _db.collection('usernames').doc(n).get();
    final uid = snap.data()?['uid'];
    if (uid is! String || uid.isEmpty) return null;
    return getUser(uid);
  }

  /// Upload new profile photo, update profile + your posts.
  Future<void> changePhoto(
    File file, {
    ValueChanged<double>? onProgress,
  }) async {
    _clearMeCache();
    final old = await me();
    final media = await MediaService.instance.upload(
      file,
      kind: MediaKind.avatar,
      onProgress: onProgress,
    );
    await _users.doc(myUid).update({
      'photoUrl': media.url,
      'photoKey': media.key,
    });
    // refresh avatar on your recent posts
    final posts = await _db
        .collection('posts')
        .where('authorId', isEqualTo: myUid)
        .limit(400)
        .get();
    if (posts.docs.isNotEmpty) {
      final batch = _db.batch();
      for (final d in posts.docs) {
        batch.update(d.reference, {'authorPhotoUrl': media.url});
      }
      await batch.commit();
    }
    if (old.photoKey.isNotEmpty) MediaService.instance.delete(old.photoKey);
  }

  Future<void> changeCover(
    File file, {
    ValueChanged<double>? onProgress,
  }) async {
    _clearMeCache();
    final old = await me();
    final media = await MediaService.instance.upload(
      file,
      kind: MediaKind.cover,
      onProgress: onProgress,
    );
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

  /// Follow (public) or send a follow request (private account).
  Future<void> follow(UserProfile target) async {
    final fresh = await getUser(target.uid) ?? target;
    if (fresh.isPrivate) return requestFollow(fresh);
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
  Future<List<UserProfile>> connections(
    String uid, {
    required bool followers,
  }) async {
    final snap = await _users
        .doc(uid)
        .collection(followers ? 'followers' : 'following')
        .orderBy('createdAt', descending: true)
        .limit(300)
        .get();
    return getUsers(snap.docs.map((d) => d.id).toList());
  }

  // ---------------- Private account + requests ----------------

  Future<void> setPrivate(bool on) async {
    _clearMeCache();
    await _users.doc(myUid).update({'isPrivate': on});
  }

  /// Your country (ISO code like 'IN').
  Future<void> setCountry(String code) async {
    _clearMeCache();
    await _users.doc(myUid).update({'country': code});
  }

  Future<void> setLanguage(String code) async {
    _clearMeCache();
    await _users.doc(myUid).update({'language': code});
  }

  DocumentReference<Map<String, dynamic>> _request(
    String target,
    String from,
  ) => _users.doc(target).collection('requests').doc(from);

  /// Did I already ask to follow [targetUid]?
  Stream<bool> hasRequested(String targetUid) =>
      _request(targetUid, myUid).snapshots().map((s) => s.exists);

  Future<void> requestFollow(UserProfile target) async {
    final me = await meCached();
    await _request(target.uid, me.uid).set({
      'username': me.username,
      'name': me.name,
      'photoUrl': me.photoUrl,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> cancelRequest(String targetUid) =>
      _request(targetUid, myUid).delete();

  /// People who asked to follow me (newest first).
  Stream<List<UserProfile>> followRequests() => _users
      .doc(myUid)
      .collection('requests')
      .orderBy('createdAt', descending: true)
      .limit(200)
      .snapshots()
      .map(
        (s) => s.docs.map((d) {
          final m = d.data();
          return UserProfile(
            uid: d.id,
            name: m['name'] is String ? m['name'] as String : '',
            username: m['username'] is String ? m['username'] as String : '',
            photoUrl: m['photoUrl'] is String ? m['photoUrl'] as String : '',
          );
        }).toList(),
      );

  /// Accept: they become my follower.
  Future<void> approveRequest(String requesterUid) async {
    final me = await meCached();
    final batch = _db.batch();
    batch.set(_users.doc(me.uid).collection('followers').doc(requesterUid), {
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.set(_users.doc(requesterUid).collection('following').doc(me.uid), {
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(_users.doc(me.uid), {
      'followersCount': FieldValue.increment(1),
    });
    batch.update(_users.doc(requesterUid), {
      'followingCount': FieldValue.increment(1),
    });
    batch.delete(_request(me.uid, requesterUid));
    await batch.commit();
  }

  Future<void> declineRequest(String requesterUid) =>
      _request(myUid, requesterUid).delete();

  /// Remove someone who follows me.
  Future<void> removeFollower(String uid) async {
    final batch = _db.batch();
    batch.delete(_users.doc(myUid).collection('followers').doc(uid));
    batch.delete(_users.doc(uid).collection('following').doc(myUid));
    batch.update(_users.doc(myUid), {
      'followersCount': FieldValue.increment(-1),
    });
    batch.update(_users.doc(uid), {'followingCount': FieldValue.increment(-1)});
    await batch.commit();
  }

  // ---------------- Block ----------------

  CollectionReference<Map<String, dynamic>> get _blocked =>
      _users.doc(myUid).collection('blocked');

  Stream<bool> isBlocked(String uid) =>
      _blocked.doc(uid).snapshots().map((s) => s.exists);

  /// Block: they can't message, follow or comment; you don't see them.
  Future<void> block(UserProfile user) async {
    await _blocked.doc(user.uid).set({
      'username': user.username,
      'name': user.name,
      'photoUrl': user.photoUrl,
      'createdAt': FieldValue.serverTimestamp(),
    });
    // stop following each other
    try {
      final iFollow = await _users
          .doc(myUid)
          .collection('following')
          .doc(user.uid)
          .get();
      if (iFollow.exists) await unfollow(user);
    } catch (_) {}
    try {
      final theyFollow = await _users
          .doc(myUid)
          .collection('followers')
          .doc(user.uid)
          .get();
      if (theyFollow.exists) await removeFollower(user.uid);
    } catch (_) {}
    try {
      await _request(myUid, user.uid).delete();
    } catch (_) {}
  }

  Future<void> unblock(String uid) => _blocked.doc(uid).delete();

  Stream<List<UserProfile>> blockedUsers() => _blocked
      .orderBy('createdAt', descending: true)
      .limit(500)
      .snapshots()
      .map(
        (s) => s.docs.map((d) {
          final m = d.data();
          return UserProfile(
            uid: d.id,
            name: m['name'] is String ? m['name'] as String : '',
            username: m['username'] is String ? m['username'] as String : '',
            photoUrl: m['photoUrl'] is String ? m['photoUrl'] as String : '',
          );
        }).toList(),
      );

  // ---------------- Private info ----------------

  /// Date of birth ('YYYY-MM-DD' or '').
  Future<String> birthDate() async {
    try {
      final s = await _users.doc(myUid).collection('private').doc('info').get();
      final v = s.data()?['birthDate'];
      return v is String ? v : '';
    } catch (_) {
      return '';
    }
  }

  Future<void> setBirthDate(DateTime d) =>
      _users.doc(myUid).collection('private').doc('info').set({
        'birthDate': formatBirthDate(d),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
}

String formatBirthDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Full years between [birth] and [now].
int ageOn(DateTime birth, DateTime now) {
  var age = now.year - birth.year;
  if (now.month < birth.month ||
      (now.month == birth.month && now.day < birth.day)) {
    age--;
  }
  return age;
}

const int kMinAge = 13;
