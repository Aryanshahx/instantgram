import '../../shared/models/post.dart';

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Your chat settings (v0.11), saved in prefs/{uid} (only you can read it;
/// our server reads the muted lists to skip notifications / ringing).
@immutable
class ChatPrefsData {
  const ChatPrefsData({
    this.pinned = const [],
    this.mutedChats = const {},
    this.mutedCalls = const {},
    this.cleared = const {},
    this.pushOff = const {},
    this.vanish = const {},
    this.themes = const {},
  });

  static const empty = ChatPrefsData();

  /// Pinned chat ids (first = top).
  final List<String> pinned;

  /// Chat ids with no message notifications.
  final Set<String> mutedChats;

  /// User ids whose calls don't ring (silent call screen + notification).
  final Set<String> mutedCalls;

  /// "Delete chat" (for you): chat id -> messages before this are hidden.
  final Map<String, DateTime> cleared;

  /// v0.12: notification kinds switched off (see [PushKinds]).
  final Set<String> pushOff;

  bool pushOn(String kind) => !pushOff.contains(kind);

  /// v0.13: disappearing messages, only on MY phone:
  /// chat id -> (mode, since when).
  final Map<String, (String, DateTime)> vanish;

  /// v0.0.1: chat id -> chat theme id (only you see it).
  final Map<String, String> themes;

  String themeOf(String chatId) => themes[chatId] ?? 'lime';

  String vanishMode(String chatId) => vanish[chatId]?.$1 ?? Disappear.off;
  DateTime? vanishSince(String chatId) => vanish[chatId]?.$2;

  bool isPinned(String chatId) => pinned.contains(chatId);
  bool isMuted(String chatId) => mutedChats.contains(chatId);
  bool callsMuted(String uid) => mutedCalls.contains(uid);
  DateTime? clearedAt(String chatId) => cleared[chatId];

  static Map<String, (String, DateTime)> _vanish(Object? v) {
    if (v is! Map) return const {};
    final out = <String, (String, DateTime)>{};
    for (final e in v.entries) {
      final x = e.value;
      if (e.key is! String || x is! Map) continue;
      final mode = Disappear.normalize(x['m']);
      if (mode == Disappear.off) continue;
      final at = x['at'];
      // just switched on (server time not back yet) -> now
      out[e.key as String] = (
        mode,
        at is Timestamp ? at.toDate() : DateTime.now(),
      );
    }
    return out;
  }

  static Map<String, String> _themes(Object? v) {
    if (v is! Map) return const {};
    return {
      for (final e in v.entries)
        if (e.key is String && e.value is String && e.value != '')
          e.key as String: e.value as String,
    };
  }

  factory ChatPrefsData.fromMap(Map<String, dynamic>? m) {
    if (m == null) return empty;
    List<String> list(Object? v) =>
        v is List ? v.whereType<String>().toList() : const [];
    final c = m['cleared'];
    return ChatPrefsData(
      pinned: list(m['pinnedChats']),
      mutedChats: list(m['mutedChats']).toSet(),
      mutedCalls: list(m['mutedCalls']).toSet(),
      pushOff: list(m['pushOff']).toSet(),
      vanish: _vanish(m['vanishChats']),
      themes: _themes(m['chatThemes']),
      cleared: {
        if (c is Map)
          for (final e in c.entries)
            if (e.key is String && e.value is Timestamp)
              e.key as String: (e.value as Timestamp).toDate(),
      },
    );
  }
}

class ChatPrefs {
  ChatPrefs._();
  static final ChatPrefs instance = ChatPrefs._();

  static const int maxPinned = 3;

  final ValueNotifier<ChatPrefsData> value = ValueNotifier(ChatPrefsData.empty);

  String? _uid;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      FirebaseFirestore.instance.collection('prefs').doc(uid);

  /// After login (main shell).
  void start(String uid) {
    if (_uid == uid && _sub != null) return;
    _sub?.cancel();
    _uid = uid;
    _sub = _doc(uid).snapshots().listen(
      (d) => value.value = ChatPrefsData.fromMap(d.data()),
      onError: (Object e) => debugPrint('chat prefs: $e'),
    );
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _uid = null;
    value.value = ChatPrefsData.empty;
  }

  /// Tests.
  @visibleForTesting
  void debugSet(ChatPrefsData d) => value.value = d;

  Future<void> _save(Map<String, dynamic> data) async {
    final uid = _uid;
    if (uid == null) return;
    await _doc(uid).set({
      ...data,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// false = too many pinned chats.
  Future<bool> togglePin(String chatId) async {
    final v = value.value;
    if (v.isPinned(chatId)) {
      await _save({
        'pinnedChats': FieldValue.arrayRemove([chatId]),
      });
      return true;
    }
    if (v.pinned.length >= maxPinned) return false;
    await _save({
      'pinnedChats': FieldValue.arrayUnion([chatId]),
    });
    return true;
  }

  Future<void> toggleMuteChat(String chatId) => _save({
    'mutedChats': value.value.isMuted(chatId)
        ? FieldValue.arrayRemove([chatId])
        : FieldValue.arrayUnion([chatId]),
  });

  Future<void> toggleMuteCalls(String uid) => _save({
    'mutedCalls': value.value.callsMuted(uid)
        ? FieldValue.arrayRemove([uid])
        : FieldValue.arrayUnion([uid]),
  });

  /// v0.12: switch one kind of phone notification on / off.
  Future<void> setPush(String kind, bool on) => _save({
    'pushOff': on
        ? FieldValue.arrayRemove([kind])
        : FieldValue.arrayUnion([kind]),
  });

  /// v0.13: disappearing messages for this chat, only on my phone.
  Future<void> setVanish(String chatId, String mode) {
    final m = Disappear.normalize(mode);
    final v = value.value;
    // show it at once
    final next = {...v.vanish};
    if (m == Disappear.off) {
      next.remove(chatId);
    } else {
      next[chatId] = (m, v.vanish[chatId]?.$2 ?? DateTime.now());
    }
    value.value = ChatPrefsData(
      pinned: v.pinned,
      mutedChats: v.mutedChats,
      mutedCalls: v.mutedCalls,
      cleared: v.cleared,
      pushOff: v.pushOff,
      vanish: next,
      themes: v.themes,
    );
    return _save({
      'vanishChats': {
        chatId: m == Disappear.off
            ? FieldValue.delete()
            : {'m': m, 'at': FieldValue.serverTimestamp()},
      },
    });
  }

  /// v0.0.1: chat theme for this chat (only you see it). 'lime' = default.
  Future<void> setTheme(String chatId, String themeId) {
    final v = value.value;
    final next = {...v.themes};
    final off = themeId.isEmpty || themeId == 'lime';
    if (off) {
      next.remove(chatId);
    } else {
      next[chatId] = themeId;
    }
    value.value = ChatPrefsData(
      pinned: v.pinned,
      mutedChats: v.mutedChats,
      mutedCalls: v.mutedCalls,
      cleared: v.cleared,
      pushOff: v.pushOff,
      vanish: v.vanish,
      themes: next,
    );
    return _save({
      'chatThemes': {chatId: off ? FieldValue.delete() : themeId},
    });
  }

  /// "Delete chat" for you: hides the chat and its messages until a new
  /// message comes. Also unpins it.
  Future<void> deleteChat(String chatId) => _save({
    'cleared': {chatId: FieldValue.serverTimestamp()},
    'pinnedChats': FieldValue.arrayRemove([chatId]),
  });

  /// Chat list order: pinned first (in pin order), then newest.
  static List<T> sortChats<T>(
    List<T> chats,
    ChatPrefsData p, {
    required String Function(T) id,
    required DateTime Function(T) updatedAt,
  }) {
    final visible = chats.where((c) {
      final cl = p.clearedAt(id(c));
      return cl == null || updatedAt(c).isAfter(cl);
    }).toList();
    int rank(T c) {
      final i = p.pinned.indexOf(id(c));
      return i < 0 ? 1 << 20 : i;
    }

    visible.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      return updatedAt(b).compareTo(updatedAt(a));
    });
    return visible;
  }
}

/// v0.12: kinds of activity notifications (Settings -> Notifications).
/// Same names as CATEGORY in backend/api/activity-push.js.
class PushKinds {
  PushKinds._();
  static const likes = 'likes';
  static const comments = 'comments';
  static const commentLikes = 'comment_likes';
  static const follows = 'follows';
  static const unfollows = 'unfollows';
  static const reposts = 'reposts';
  static const views = 'views';

  /// (kind, title, subtitle) in the order shown in Settings.
  static const all = <(String, String, String)>[
    (likes, 'Likes', 'Someone liked your post or clip'),
    (comments, 'Comments and replies', 'New comments and replies to you'),
    (commentLikes, 'Comment likes', 'Someone liked your comment'),
    (follows, 'New followers', 'Someone started following you'),
    (unfollows, 'Unfollows', 'Someone stopped following you'),
    (reposts, 'Reposts', 'Someone reposted your post or clip'),
    (views, 'Views', 'Your post or clip reached 100, 1K, 10K ... views'),
  ];
}
