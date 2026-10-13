import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../shared/models/post.dart';

/// Decides what the signed-in user may see:
/// blocked users, private accounts and post audience.
class ContentFilter {
  ContentFilter._();
  static final ContentFilter instance = ContentFilter._();

  String _me = '';
  Set<String> _following = {};
  Set<String> _blocked = {};
  Set<String> _private = {};

  /// Changes every time one of the lists changes (use to rebuild).
  final ValueNotifier<int> version = ValueNotifier(0);

  final List<StreamSubscription<dynamic>> _subs = [];

  String get me => _me;

  /// Signed-in uid ('' when signed out / in tests). Never throws.
  String get uid {
    if (_me.isNotEmpty) return _me;
    try {
      return FirebaseAuth.instance.currentUser?.uid ?? '';
    } catch (_) {
      return '';
    }
  }

  Set<String> get following => _following;
  Set<String> get blocked => _blocked;
  bool isBlocked(String uid) => _blocked.contains(uid);
  bool isFollowing(String uid) => _following.contains(uid);
  bool isPrivate(String uid) => _private.contains(uid);

  void _bump() => version.value++;

  /// Start listening for [uid] (called when the main screen opens).
  void start(String uid) {
    if (_me == uid && _subs.isNotEmpty) return;
    stop();
    _me = uid;
    final db = FirebaseFirestore.instance;
    final user = db.collection('users').doc(uid);
    void onErr(Object _) {}
    _subs.add(
      user.collection('following').limit(1000).snapshots().listen((s) {
        _following = s.docs.map((d) => d.id).toSet();
        _bump();
      }, onError: onErr),
    );
    _subs.add(
      user.collection('blocked').limit(1000).snapshots().listen((s) {
        _blocked = s.docs.map((d) => d.id).toSet();
        _bump();
      }, onError: onErr),
    );
    _subs.add(
      db
          .collection('users')
          .where('isPrivate', isEqualTo: true)
          .limit(1000)
          .snapshots()
          .listen((s) {
            _private = s.docs.map((d) => d.id).toSet();
            _bump();
          }, onError: onErr),
    );
  }

  void stop() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _me = '';
    _following = {};
    _blocked = {};
    _private = {};
    _bump();
  }

  /// For tests.
  @visibleForTesting
  void debugSet({
    String me = 'me',
    Set<String> following = const {},
    Set<String> blocked = const {},
    Set<String> private = const {},
  }) {
    _me = me;
    _following = {...following};
    _blocked = {...blocked};
    _private = {...private};
    _bump();
  }

  /// Can I see content from [authorId] with this [audience]?
  bool canSeeFrom(String authorId, String audience) {
    if (authorId == uid) return true;
    if (_blocked.contains(authorId)) return false;
    switch (audience) {
      case Audience.onlyMe:
        return false;
      case Audience.followers:
        return _following.contains(authorId);
    }
    if (_private.contains(authorId)) return _following.contains(authorId);
    return true;
  }

  bool canSee(Post p) => canSeeFrom(p.authorId, p.audience);
  bool canSeeStory(Story s) => canSeeFrom(s.authorId, s.audience);

  List<Post> filter(List<Post> list) => list.where(canSee).toList();

  /// Re-filters [source] whenever the lists change.
  Stream<List<T>> watch<T>(Stream<List<T>> source, bool Function(T item) test) {
    late StreamController<List<T>> ctrl;
    StreamSubscription<List<T>>? sub;
    List<T>? last;
    void emit() {
      final l = last;
      if (l != null && !ctrl.isClosed) ctrl.add(l.where(test).toList());
    }

    ctrl = StreamController<List<T>>(
      onListen: () {
        version.addListener(emit);
        sub = source.listen(
          (v) {
            last = v;
            emit();
          },
          onError: ctrl.addError,
          onDone: ctrl.close,
        );
      },
      onCancel: () async {
        version.removeListener(emit);
        await sub?.cancel();
      },
    );
    return ctrl.stream;
  }

  Stream<List<Post>> visiblePosts(Stream<List<Post>> source) =>
      watch<Post>(source, canSee);
}
