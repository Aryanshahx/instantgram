import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/post.dart';
import 'user_service.dart';

/// A person in the blocked list or among the follow requests.
class PersonRef {
  const PersonRef({required this.uid, this.username = '', this.photoUrl = ''});
  final String uid;
  final String username;
  final String photoUrl;
}

/// Who I blocked, who I follow, follow requests for private accounts, and the one rule that
/// decides which posts I may see.
class SafetyService {
  SafetyService._();
  static final SafetyService instance = SafetyService._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  String get _uid => FirebaseAuth.instance.currentUser!.uid;

  /// My uid ('' before [load]). Tests set it directly.
  String me = '';

  /// People I blocked.
  final ValueNotifier<Set<String>> blocked = ValueNotifier(const {});

  /// Posts reported by this many people are hidden for everybody but the author
  /// (set in the admin panel, config/app.autoHide; 0 = off).
  int autoHide = 0;

  /// People I follow (the newest 100, like the rest of the app).
  Set<String> following = {};

  /// Loads the lists once after login.
  Future<void> load() async {
    try {
      me = _uid;
      final results = await Future.wait<Object>([
        _db.collection('users').doc(me).collection('blocked').get(),
        UserService.instance.followingIds(),
      ]);
      final snap = results[0] as QuerySnapshot<Map<String, dynamic>>;
      blocked.value = {for (final d in snap.docs) d.id};
      following = {...(results[1] as List<String>)};
      await completeApproved();
      try {
        final c = await _db.collection('config').doc('app').get();
        final n = c.data()?['autoHide'];
        autoHide = n is num ? n.toInt() : 0;
      } catch (_) {
        autoHide = 0;
      }
    } catch (_) {
      // the lists are best effort; everything is shown when they cannot be read
    }
  }

  void clear() {
    me = '';
    blocked.value = const {};
    following = {};
    autoHide = 0;
  }

  // ------------------------------------------------------------ visibility

  /// Whether the post may be shown to me.
  bool canSee(Post p) {
    if (p.authorId == me) return true;
    if (p.hidden) return false;
    if (autoHide > 0 && p.effectiveReports >= autoHide) return false;
    if (blocked.value.contains(p.authorId)) return false;
    if (p.audience == kAudienceMe) return false;
    if (p.audience == kAudienceFollowers || p.authorPrivate) {
      return following.contains(p.authorId);
    }
    return true;
  }

  List<Post> visible(Iterable<Post> posts) => [
    for (final p in posts)
      if (canSee(p)) p,
  ];

  /// Likes / comments / shares are shown to the author always, to others unless hidden.
  bool showsNumber(Post p, bool hidden) => !hidden || p.authorId == me;

  // ------------------------------------------------------------- blocking

  bool isBlocked(String uid) => blocked.value.contains(uid);

  Future<void> block(PersonRef p) async {
    await _db
        .collection('users')
        .doc(_uid)
        .collection('blocked')
        .doc(p.uid)
        .set({
          'username': p.username,
          'photoUrl': p.photoUrl,
          'createdAt': FieldValue.serverTimestamp(),
        });
    blocked.value = {...blocked.value, p.uid};
    if (following.contains(p.uid)) {
      try {
        await UserService.instance.unfollow(p.uid);
      } catch (_) {}
      following.remove(p.uid);
    }
  }

  Future<void> unblock(String uid) async {
    await _db
        .collection('users')
        .doc(_uid)
        .collection('blocked')
        .doc(uid)
        .delete();
    blocked.value = {...blocked.value}..remove(uid);
  }

  Future<List<PersonRef>> blockedPeople() async {
    final snap = await _db
        .collection('users')
        .doc(_uid)
        .collection('blocked')
        .orderBy('createdAt', descending: true)
        .get();
    return [
      for (final d in snap.docs)
        PersonRef(
          uid: d.id,
          username: (d.data()['username'] as String?) ?? '',
          photoUrl: (d.data()['photoUrl'] as String?) ?? '',
        ),
    ];
  }

  // ------------------------------------------------------ private accounts

  /// Turns the private account switch on or off. Posts made earlier are updated too (the
  /// newest 400), so they follow the setting.
  Future<void> setPrivate(bool value) async {
    final users = _db.collection('users');
    await users.doc(_uid).update({'isPrivate': value});
    final snap = await _db
        .collection('posts')
        .where('authorId', isEqualTo: _uid)
        .orderBy('createdAt', descending: true)
        .limit(400)
        .get();
    for (var i = 0; i < snap.docs.length; i += 400) {
      final batch = _db.batch();
      for (final d in snap.docs.skip(i).take(400)) {
        batch.update(d.reference, {'authorPrivate': value});
      }
      await batch.commit();
    }
  }

  /// I ask to follow a private account.
  Future<void> requestFollow(String target, {String username = ''}) async {
    final me = await UserService.instance.getUser(_uid);
    final batch = _db.batch();
    batch.set(
      _db.collection('users').doc(target).collection('requests').doc(_uid),
      {
        'username': me?.username ?? username,
        'photoUrl': me?.photoUrl ?? '',
        'createdAt': FieldValue.serverTimestamp(),
      },
    );
    batch.set(
      _db.collection('users').doc(_uid).collection('sent_requests').doc(target),
      {'createdAt': FieldValue.serverTimestamp()},
    );
    await batch.commit();
  }

  Future<void> cancelRequest(String target) async {
    final batch = _db.batch();
    batch.delete(
      _db.collection('users').doc(target).collection('requests').doc(_uid),
    );
    batch.delete(
      _db.collection('users').doc(_uid).collection('sent_requests').doc(target),
    );
    await batch.commit();
  }

  Future<bool> hasRequested(String target) async {
    final d = await _db
        .collection('users')
        .doc(_uid)
        .collection('sent_requests')
        .doc(target)
        .get();
    return d.exists;
  }

  Future<List<PersonRef>> incomingRequests() async {
    final snap = await _db
        .collection('users')
        .doc(_uid)
        .collection('requests')
        .orderBy('createdAt', descending: true)
        .get();
    return [
      for (final d in snap.docs)
        PersonRef(
          uid: d.id,
          username: (d.data()['username'] as String?) ?? '',
          photoUrl: (d.data()['photoUrl'] as String?) ?? '',
        ),
    ];
  }

  /// I approve [requester]. They start following me the next time they open the app.
  Future<void> accept(String requester) async {
    final batch = _db.batch();
    final mine = _db.collection('users').doc(_uid);
    batch.set(mine.collection('approved').doc(requester), {
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.delete(mine.collection('requests').doc(requester));
    await batch.commit();
  }

  Future<void> decline(String requester) => _db
      .collection('users')
      .doc(_uid)
      .collection('requests')
      .doc(requester)
      .delete();

  /// Requests I sent that were approved: now the follow can be made.
  Future<void> completeApproved() async {
    final mine = _db.collection('users').doc(_uid);
    final sent = await mine.collection('sent_requests').get();
    for (final d in sent.docs) {
      final target = d.id;
      final ok = await _db
          .collection('users')
          .doc(target)
          .collection('approved')
          .doc(_uid)
          .get();
      if (!ok.exists) continue;
      try {
        await UserService.instance.follow(target);
        following.add(target);
        await d.reference.delete();
        await ok.reference.delete();
      } catch (_) {}
    }
  }
}
