import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/calls.dart';
import '../../../core/services/chat_prefs.dart';
import '../../../shared/models/post.dart';

/// v0.0.2: channel posts reach phones through push "topics": one push
/// per post for all followers. This phone listens to:
/// - every channel you follow and did not mute ("ch_...")
/// - `u_<your id>` so your own posts don't notify you.
/// The list is kept on the phone, so switching accounts cleans it up.
class ChannelTopics {
  ChannelTopics._();
  static final ChannelTopics instance = ChannelTopics._();

  static const String _key = 'push_topics';

  /// Tests: subscribe / unsubscribe (true = ok).
  Future<bool> Function(String topic, bool on)? debugSet;

  String _uid = '';
  List<Chat> _chats = const [];
  Future<void> _chain = Future.value();
  bool _listening = false;

  /// Topics this phone should listen to.
  static Set<String> wanted(
    String uid,
    List<Chat> chats,
    bool Function(String id) muted,
  ) => {
    if (uid.isNotEmpty) 'u_$uid',
    for (final c in chats)
      if (c.isChannel && c.isMember(uid) && !muted(c.id)) c.id,
  };

  /// Your chats changed (called by the chat list watcher).
  void update(String uid, List<Chat> chats) {
    if (Calls.disabled && debugSet == null) return;
    _uid = uid;
    _chats = chats;
    if (!_listening) {
      _listening = true;
      ChatPrefs.instance.value.addListener(_again);
    }
    _again();
  }

  void _again() {
    if (_uid.isEmpty) return;
    final want = wanted(_uid, _chats, ChatPrefs.instance.value.value.isMuted);
    _chain = _chain.then((_) => _apply(want)).catchError((Object e) {
      debugPrint('topics: $e');
    });
  }

  /// Signed out: stop all channel pushes on this phone.
  Future<void> stop() async {
    if (_listening) {
      ChatPrefs.instance.value.removeListener(_again);
      _listening = false;
    }
    _uid = '';
    _chats = const [];
    if (Calls.disabled && debugSet == null) return;
    final done = _chain.then((_) => _apply(const {}));
    _chain = done.catchError((Object e) {
      debugPrint('topics: $e');
    });
    try {
      await done.timeout(const Duration(seconds: 6));
    } catch (e) {
      debugPrint('topics stop: $e');
    }
  }

  Future<void> _apply(Set<String> want) async {
    final p = await SharedPreferences.getInstance();
    final have = (p.getStringList(_key) ?? const <String>[]).toSet();
    for (final t in have.difference(want)) {
      if (await _set(t, false)) have.remove(t);
    }
    for (final t in want.difference(have)) {
      if (await _set(t, true)) have.add(t);
    }
    await p.setStringList(_key, have.toList()..sort());
  }

  Future<bool> _set(String topic, bool on) async {
    try {
      final f = debugSet;
      if (f != null) return await f(topic, on);
      final fm = FirebaseMessaging.instance;
      if (on) {
        await fm.subscribeToTopic(topic);
      } else {
        await fm.unsubscribeFromTopic(topic);
      }
      return true;
    } catch (e) {
      debugPrint('topic $topic: $e');
      return false;
    }
  }
}
