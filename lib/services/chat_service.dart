import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/chat.dart';
import 'media_server.dart';
import 'user_service.dart';

/// Direct messages between any two people.
///
///   chats/{uidA_uidB}            members, lastText, lastAt, lastSender, seen.{uid}
///   chats/{uidA_uidB}/messages   senderId, type, text, createdAt (+ media, reply, reactions...)
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

  /// Sends a plain text message.
  Future<void> send(String otherUid, String text, {ReplyRef? replyTo}) async {
    final body = text.trim();
    if (body.isEmpty) return;
    if (body.length > maxLength) {
      throw StateError('That message is too long.');
    }
    await _write(
      otherUid,
      {'type': MsgType.text, 'text': body},
      body,
      replyTo: replyTo,
    );
  }

  /// A photo already uploaded to our storage.
  Future<void> sendImage(
    String otherUid, {
    required String mediaRef,
    required int width,
    required int height,
    ReplyRef? replyTo,
  }) => _write(
    otherUid,
    {
      'type': MsgType.image,
      'text': '',
      'mediaUrl': mediaRef,
      'width': width,
      'height': height,
    },
    messagePreview(MsgType.image, ''),
    replyTo: replyTo,
  );

  /// A GIF from Giphy (we only store its link).
  Future<void> sendGif(
    String otherUid, {
    required String url,
    required int width,
    required int height,
    ReplyRef? replyTo,
  }) => _write(
    otherUid,
    {
      'type': MsgType.gif,
      'text': '',
      'mediaUrl': url,
      'width': width,
      'height': height,
    },
    messagePreview(MsgType.gif, ''),
    replyTo: replyTo,
  );

  /// A voice note already uploaded to our storage.
  Future<void> sendVoice(
    String otherUid, {
    required String mediaRef,
    required int seconds,
    ReplyRef? replyTo,
  }) => _write(
    otherUid,
    {
      'type': MsgType.voice,
      'text': '',
      'mediaUrl': mediaRef,
      'duration': seconds,
    },
    messagePreview(MsgType.voice, ''),
    replyTo: replyTo,
  );

  Future<void> sendLocation(
    String otherUid, {
    required double lat,
    required double lng,
    ReplyRef? replyTo,
  }) => _write(
    otherUid,
    {'type': MsgType.location, 'text': '', 'lat': lat, 'lng': lng},
    messagePreview(MsgType.location, ''),
    replyTo: replyTo,
  );

  /// Shares a post or clip with [otherUid]; [note] is an optional line sent with it.
  Future<void> sendPost(
    String otherUid, {
    required String postId,
    required String thumbRef,
    required String title,
    required String author,
    required bool isClip,
    String note = '',
  }) => _write(
    otherUid,
    {
      'type': MsgType.post,
      'text': note.trim().length > maxLength
          ? note.trim().substring(0, maxLength)
          : note.trim(),
      'postId': postId,
      'postThumb': thumbRef,
      'postTitle': title.length > 200 ? title.substring(0, 200) : title,
      'postAuthor': author,
      'postIsClip': isClip,
    },
    messagePreview(MsgType.post, '', postIsClip: isClip),
    ensureChat: true,
  );

  /// Sends a copy of [m] to every person in [uids], marked "Forwarded".
  Future<void> forward(ChatMessage m, List<String> uids) async {
    if (m.deleted) return;
    final fields = <String, dynamic>{'type': m.type, 'text': m.text};
    switch (m.type) {
      case MsgType.image:
      case MsgType.gif:
        fields.addAll({
          'mediaUrl': m.mediaRef,
          'width': m.width,
          'height': m.height,
        });
      case MsgType.voice:
        fields.addAll({'mediaUrl': m.mediaRef, 'duration': m.duration});
      case MsgType.location:
        fields.addAll({'lat': m.lat, 'lng': m.lng});
      case MsgType.post:
        fields.addAll({
          'postId': m.postId,
          'postThumb': m.postThumbRef,
          'postTitle': m.postTitle,
          'postAuthor': m.postAuthor,
          'postIsClip': m.postIsClip,
        });
    }
    fields['forwarded'] = true;
    final preview = m.preview;
    for (final uid in uids) {
      await _write(uid, fields, preview, ensureChat: true);
    }
  }

  Future<void> _write(
    String otherUid,
    Map<String, dynamic> fields,
    String preview, {
    ReplyRef? replyTo,
    bool ensureChat = false,
  }) async {
    final me = _me;
    if (ensureChat) await open(otherUid);
    final ref = _chats.doc(chatIdFor(me, otherUid));
    final batch = _db.batch();
    batch.set(ref.collection('messages').doc(), {
      ...fields,
      'senderId': me,
      'createdAt': FieldValue.serverTimestamp(),
      if (replyTo != null) 'replyTo': replyTo.toMap(),
    });
    batch.update(ref, {
      'lastText': preview.length > 140 ? preview.substring(0, 140) : preview,
      'lastAt': FieldValue.serverTimestamp(),
      'lastSender': me,
      'seen.$me': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }

  DocumentReference<Map<String, dynamic>> _msg(String chatId, String id) =>
      _chats.doc(chatId).collection('messages').doc(id);

  /// Sets (or with a null [emoji] removes) my reaction. Tapping the same emoji again
  /// removes it.
  Future<void> react(String chatId, ChatMessage m, String? emoji) async {
    final me = _me;
    final same = m.reactions[me] == emoji;
    await _msg(chatId, m.id).update({
      'reactions.$me': (emoji == null || same) ? FieldValue.delete() : emoji,
    });
  }

  /// Removes the message from my own view only.
  Future<void> deleteForMe(String chatId, String messageId) =>
      _msg(chatId, messageId).update({
        'hiddenFor': FieldValue.arrayUnion([_me]),
      });

  /// Replaces my message with "This message was deleted" for everyone.
  Future<void> deleteForEveryone(String chatId, ChatMessage m) async {
    await _msg(chatId, m.id).update({
      'deleted': true,
      'text': '',
      'mediaUrl': '',
      'postThumb': '',
      'postTitle': '',
      'lat': 0,
      'lng': 0,
      'replyTo': FieldValue.delete(),
      'pinned': false,
    });
    if (m.pinned) await _clearPin(chatId);
    if (m.type == MsgType.image || m.type == MsgType.voice) {
      unawaited(MediaServer.instance.deleteQuietly(m.mediaRef));
    }
  }

  Future<void> _clearPin(String chatId) => _chats.doc(chatId).update({
    'pinnedId': FieldValue.delete(),
    'pinnedPreview': FieldValue.delete(),
    'pinnedBy': FieldValue.delete(),
  });

  /// Pins [m] at the top of the chat (one pin per chat) or unpins it.
  Future<void> setPinned(String chatId, ChatMessage m, bool pinned) async {
    final chat = _chats.doc(chatId);
    final snap = await chat.get();
    final oldId = snap.data()?['pinnedId'];
    if (oldId is String && oldId.isNotEmpty && oldId != m.id) {
      try {
        await _msg(chatId, oldId).update({'pinned': false});
      } catch (_) {
        // the old message may be gone
      }
    }
    await _msg(chatId, m.id).update({'pinned': pinned});
    if (pinned) {
      await chat.update({
        'pinnedId': m.id,
        'pinnedPreview': m.preview.length > 100
            ? m.preview.substring(0, 100)
            : m.preview,
        'pinnedBy': _me,
      });
    } else {
      await _clearPin(chatId);
    }
  }

  /// The pinned message of a chat as `{id, preview, by}`, or null.
  Stream<({String id, String preview, String by})?> watchPin(String chatId) =>
      _chats.doc(chatId).snapshots().map((d) {
        final m = d.data();
        final id = m?['pinnedId'];
        if (id is! String || id.isEmpty) return null;
        final p = m?['pinnedPreview'];
        final by = m?['pinnedBy'];
        return (
          id: id,
          preview: p is String ? p : '',
          by: by is String ? by : '',
        );
      });

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
