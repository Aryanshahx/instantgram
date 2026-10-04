import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/chat.dart';
import 'user_service.dart';

/// Direct messages between any two people.
///
///   chats/{uidA_uidB}            members, lastText, lastAt, lastSender, seen.{uid}
///   chats/{uidA_uidB}/messages   senderId, text, createdAt
class ChatService {
  ChatService._();
  static final ChatService instance = ChatService._();

  static const int maxLength = 2000;

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _chats =>
      _db.collection('chats');
  String get _me => UserService.instance.myUid;

  /// The inbox: conversations that have at least one message, newest first.
  final ValueNotifier<List<ChatThread>> threads = ValueNotifier(const []);
  final ValueNotifier<Object?> error = ValueNotifier(null);
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;

  /// How many conversations have a message that was not opened yet.
  int get unreadCount {
    final me = _me;
    return threads.value.where((t) => t.isUnread(me)).length;
  }

  /// Starts listening to the inbox (once; called by the main screen).
  void start() {
    if (_sub != null) return;
    final me = _me;
    _sub = _chats
        .where('members', arrayContains: me)
        .snapshots()
        .listen(
          (snap) {
            final list =
                snap.docs
                    .map(ChatThread.fromDoc)
                    .where((t) => t.hasMessages)
                    .toList()
                  ..sort(
                    (a, b) => (b.lastAt ?? DateTime.now()).compareTo(
                      a.lastAt ?? DateTime.now(),
                    ),
                  );
            error.value = null;
            threads.value = list;
          },
          onError: (Object e) {
            error.value = e;
          },
        );
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    threads.value = const [];
    error.value = null;
  }

  /// Makes sure the chat with [otherUid] exists and returns its id.
  Future<String> open(String otherUid) async {
    final me = _me;
    final id = chatIdFor(me, otherUid);
    final ref = _chats.doc(id);
    final snap = await ref.get();
    if (!snap.exists) {
      await ref.set({
        'members': chatMembers(me, otherUid),
        'lastText': '',
        'lastSender': '',
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    return id;
  }

  Stream<List<ChatMessage>> watchMessages(String chatId) => _chats
      .doc(chatId)
      .collection('messages')
      .orderBy('createdAt', descending: true)
      .limit(300)
      .snapshots()
      .map((s) => s.docs.map(ChatMessage.fromDoc).toList());

  Future<void> send(String otherUid, String text) async {
    final body = text.trim();
    if (body.isEmpty) return;
    if (body.length > maxLength) {
      throw StateError('That message is too long.');
    }
    final me = _me;
    final ref = _chats.doc(chatIdFor(me, otherUid));
    final batch = _db.batch();
    batch.set(ref.collection('messages').doc(), {
      'senderId': me,
      'text': body,
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(ref, {
      'lastText': body.length > 140 ? body.substring(0, 140) : body,
      'lastAt': FieldValue.serverTimestamp(),
      'lastSender': me,
      'seen.$me': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }

  /// Marks the chat as read for me.
  Future<void> markSeen(String chatId) async {
    try {
      await _chats.doc(chatId).update({
        'seen.$_me': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // not important enough to bother the user
    }
  }
}
