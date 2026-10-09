import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../core/fonts.dart';
import '../models/chat.dart';
import '../models/vanish.dart';
import 'media_server.dart';
import 'user_service.dart';
import 'push_service.dart';
import 'feed_signals.dart';
import 'moderation.dart';

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
                    .map((d) => ChatThread.fromDoc(d, me: _me))
                    .where((t) => t.hasMessages)
                    .toList()
                  ..sort((a, b) {
                    // pinned first, then the newest message
                    final p = (b.pinned ? 1 : 0).compareTo(a.pinned ? 1 : 0);
                    if (p != 0) return p;
                    return (b.lastAt ?? DateTime.now()).compareTo(
                      a.lastAt ?? DateTime.now(),
                    );
                  });
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

  /// Pin, or mute calls or messages of one chat (only the fields that are given).
  Future<void> setChatFlags(
    String chatId, {
    bool? pinned,
    bool? muteCalls,
    bool? muteMessages,
  }) async {
    // per person: only my own entry changes (the other person keeps theirs)
    final me = _me;
    final patch = <String, dynamic>{
      if (pinned != null) 'pinned': {me: pinned},
      if (muteCalls != null) 'muteCalls': {me: muteCalls},
      if (muteMessages != null) 'muteMessages': {me: muteMessages},
    };
    if (patch.isEmpty) return;
    await _chats.doc(chatId).set(patch, SetOptions(merge: true));
  }

  /// Removes the chat for you: the messages go first, then the conversation itself.
  Future<void> deleteChat(String chatId) async {
    final messages = await _chats
        .doc(chatId)
        .collection('messages')
        .limit(400)
        .get();
    var batch = _db.batch();
    var n = 0;
    for (final d in messages.docs) {
      batch.delete(d.reference);
      n++;
      if (n == 400) {
        await batch.commit();
        batch = _db.batch();
        n = 0;
      }
    }
    if (n > 0) await batch.commit();
    await _chats.doc(chatId).delete();
  }

  /// Makes sure the chat with [otherUid] exists and returns its id.
  Future<String> open(String otherUid) async {
    final me = _me;
    final id = chatIdFor(me, otherUid);
    final ref = _chats.doc(id);
    // A chat that was opened before is in the phone's cache: no waiting for the server.
    try {
      final cached = await ref.get(const GetOptions(source: Source.cache));
      if (cached.exists) return id;
    } catch (_) {
      // not cached yet: ask the server
    }
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
  /// [font] is a kAppFonts id: the other person sees the same font ('' = normal).
  Future<void> send(
    String otherUid,
    String text, {
    ReplyRef? replyTo,
    String font = '',
  }) async {
    Closeness.instance.bump(otherUid, Signal.message);
    // chats are private: only blocked words are starred
    final body = Moderation.instance.chatText(text.trim());
    if (body.isEmpty) return;
    if (body.length > maxLength) {
      throw StateError('That message is too long.');
    }
    await _write(
      otherUid,
      {
        'type': MsgType.text,
        'text': body,
        if (cleanFontId(font).isNotEmpty) 'font': cleanFontId(font),
      },
      body,
      replyTo: replyTo,
    );
  }

  /// A photo already uploaded to our storage.
  Future<String> sendImage(
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

  /// The line "Voice call 2:31" / "Missed video call" in the chat. Only the caller writes it.
  Future<void> sendCallLog(
    String otherUid, {
    required bool video,
    required String status,
    int seconds = 0,
  }) => _write(
    otherUid,
    {
      'type': MsgType.call,
      'text': '',
      'callVideo': video,
      'callStatus': status,
      'duration': seconds,
    },
    messagePreview(MsgType.call, '', callVideo: video, callStatus: status),
    ensureChat: true,
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

  /// Returns the id of the new message. The returned future completes when the server has
  /// the message; the message itself is already visible in the chat before that.
  Future<String> _write(
    String otherUid,
    Map<String, dynamic> fields,
    String preview, {
    ReplyRef? replyTo,
    bool ensureChat = false,
  }) async {
    final me = _me;
    if (ensureChat) await open(otherUid);
    final chatId = chatIdFor(me, otherUid);
    final ref = _chats.doc(chatId);
    // disappearing messages (never for call lines)
    final mode = fields['type'] == MsgType.call ? '' : (_vanish[chatId] ?? '');
    final expire = Vanish.expireAt(mode, DateTime.now());
    final line = mode.isNotEmpty ? Vanish.preview : preview;
    final batch = _db.batch();
    final msg = ref.collection('messages').doc();
    batch.set(msg, {
      ...fields,
      if (mode.isNotEmpty) 'vanish': mode,
      if (expire != null) 'expireAt': Timestamp.fromDate(expire),
      'senderId': me,
      'createdAt': FieldValue.serverTimestamp(),
      if (replyTo != null) 'replyTo': replyTo.toMap(),
    });
    batch.update(ref, {
      'lastText': line.length > 140 ? line.substring(0, 140) : line,
      'lastAt': FieldValue.serverTimestamp(),
      'lastSender': me,
      'seen.$me': FieldValue.serverTimestamp(),
    });
    await batch.commit();
    if (fields['type'] != MsgType.call) {
      PushService.instance.message(chatId, msg.id); // the other phone
    }
    return msg.id;
  }

  // ------------------------------------------------------ disappearing messages

  /// The mode of every chat that is open (or was), so new messages follow it.
  final Map<String, String> _vanish = {};

  /// The disappearing-messages mode of a chat, live ('' = off).
  Stream<String> watchVanish(String chatId) =>
      _chats.doc(chatId).snapshots().map((d) {
        final v = '${d.data()?['vanish'] ?? ''}';
        final mode = Vanish.isValid(v) ? v : Vanish.off;
        _vanish[chatId] = mode;
        return mode;
      });

  /// Turns disappearing messages on or off and writes a note into the chat.
  Future<void> setVanish(
    String otherUid,
    String mode, {
    required String myName,
  }) async {
    if (!Vanish.isValid(mode)) throw ArgumentError(mode);
    final me = _me;
    final chatId = chatIdFor(me, otherUid);
    final ref = _chats.doc(chatId);
    final batch = _db.batch();
    batch.update(ref, {
      'vanish': mode,
      'vanishBy': me,
      'vanishAt': FieldValue.serverTimestamp(),
    });
    batch.set(ref.collection('messages').doc(), {
      'type': MsgType.system,
      'text': Vanish.systemText(myName, mode),
      'senderId': me,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
    _vanish[chatId] = mode;
  }

  /// Removes messages whose time is up (anyone in the chat may do it).
  Future<int> sweepExpired(String chatId) async {
    try {
      final snap = await _chats
          .doc(chatId)
          .collection('messages')
          .where('expireAt', isLessThanOrEqualTo: Timestamp.now())
          .limit(400)
          .get();
      if (snap.docs.isEmpty) return 0;
      final batch = _db.batch();
      for (final d in snap.docs) {
        batch.delete(d.reference);
      }
      await batch.commit();
      return snap.docs.length;
    } catch (_) {
      return 0; // offline: next time
    }
  }

  /// "After seen" messages I received and had on screen: gone once I leave the chat.
  Future<int> removeSeen(String chatId, Iterable<ChatMessage> shown) async {
    final me = _me;
    final mine = [
      for (final m in shown)
        if (m.vanish == Vanish.seen && m.senderId != me && !m.pending) m,
    ];
    if (mine.isEmpty) return 0;
    try {
      final batch = _db.batch();
      for (final m in mine) {
        batch.delete(_msg(chatId, m.id));
      }
      await batch.commit();
    } catch (_) {
      return 0;
    }
    return mine.length;
  }

  /// Wipes a message of mine that should not exist (its photo was rejected).
  Future<void> discardMine(String otherUid, String messageId) => _msg(
    chatIdFor(_me, otherUid),
    messageId,
  ).update({'deleted': true, 'text': '', 'mediaUrl': ''});

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

  /// When [uid] last opened the chat (for "Seen" under my last message), live.
  Stream<DateTime?> watchSeenBy(String chatId, String uid) =>
      _chats.doc(chatId).snapshots().map((d) {
        final s = d.data()?['seen'];
        final v = s is Map ? s[uid] : null;
        return v is Timestamp ? v.toDate() : null;
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
