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

  bool isPinned(String chatId) => pinned.contains(chatId);
  bool isMuted(String chatId) => mutedChats.contains(chatId);
  bool callsMuted(String uid) => mutedCalls.contains(uid);
  DateTime? clearedAt(String chatId) => cleared[chatId];

  factory ChatPrefsData.fromMap(Map<String, dynamic>? m) {
    if (m == null) return empty;
    List<String> list(Object? v) =>
        v is List ? v.whereType<String>().toList() : const [];
    final c = m['cleared'];
    return ChatPrefsData(
      pinned: list(m['pinnedChats']),
      mutedChats: list(m['mutedChats']).toSet(),
      mutedCalls: list(m['mutedCalls']).toSet(),
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
