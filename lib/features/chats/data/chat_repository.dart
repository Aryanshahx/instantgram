import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/painting.dart' show decodeImageFromList;

import '../../../core/services/api_client.dart';
import '../../../core/services/gif_search.dart';
import '../../../core/services/server_clock.dart';
import '../../../core/services/media_service.dart';

import '../../../shared/models/post.dart';
import '../../../shared/models/user_profile.dart';
import '../../profile/data/user_repository.dart';

class ChatRepository {
  ChatRepository._();
  static final ChatRepository instance = ChatRepository._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _chats =>
      _db.collection('chats');
  String get myUid => FirebaseAuth.instance.currentUser!.uid;

  /// Same id for both people: smallerUid_biggerUid
  String chatIdWith(String otherUid) {
    final ids = [myUid, otherUid]..sort();
    return ids.join('_');
  }

  Stream<List<Chat>> myChats() => _chats
      .where('members', arrayContains: myUid)
      .orderBy('updatedAt', descending: true)
      .limit(100)
      .snapshots()
      .map((s) => s.docs.map(Chat.fromDoc).toList());

  /// One chat (pinned message…). null = no messages yet.
  Stream<Chat?> chat(String chatId) => _chats
      .doc(chatId)
      .snapshots()
      .map((d) => d.exists ? Chat.fromDoc(d) : null);

  Stream<List<Message>> messages(String chatId) => _chats
      .doc(chatId)
      .collection('messages')
      .orderBy('createdAt', descending: true)
      .limit(200)
      // v0.10: also hear "saved on the server" (clock -> tick)
      .snapshots(includeMetadataChanges: true)
      .map((s) => s.docs.map(Message.fromDoc).toList());

  // ------------------------------------------------------------ v0.10 ticks

  /// You saw the chat (green ticks for the other person).
  Future<void> markSeen(String chatId) => _chats.doc(chatId).update({
    'seen.$myUid': FieldValue.serverTimestamp(),
    'delivered.$myUid': FieldValue.serverTimestamp(),
  });

  /// New messages reached your phone (double grey ticks).
  Future<void> markDelivered(String chatId) => _chats.doc(chatId).update({
    'delivered.$myUid': FieldValue.serverTimestamp(),
  });

  Future<void> send(
    UserProfile other,
    String text, {
    MessageQuote? replyTo,
  }) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _write(ChatPerson.of(other), {
      'text': t,
      if (replyTo != null) 'replyTo': replyTo.toMap(),
    }, t);
  }

  // ------------------------------------------------------------ v0.9 media

  /// Photo from the phone (uploaded to Tigris first).
  Future<void> sendImage(
    ChatPerson other,
    File file, {
    MessageQuote? replyTo,
    void Function(double)? onProgress,
  }) async {
    var w = 0, h = 0;
    try {
      final img = await decodeImageFromList(await file.readAsBytes());
      w = img.width;
      h = img.height;
      img.dispose();
    } catch (_) {}
    final up = await MediaService.instance.upload(
      file,
      kind: MediaKind.chat,
      onProgress: onProgress,
    );
    await _write(other, {
      'kind': Message.image,
      'text': '',
      'mediaUrl': up.url,
      'mediaKey': up.key,
      'width': w,
      'height': h,
      if (replyTo != null) 'replyTo': replyTo.toMap(),
    }, '📷 Photo');
  }

  /// GIF from GIPHY (nothing to upload).
  Future<void> sendGif(
    ChatPerson other,
    GifResult gif, {
    MessageQuote? replyTo,
  }) => _write(other, {
    'kind': Message.gif,
    'text': '',
    'mediaUrl': gif.url,
    'width': gif.width,
    'height': gif.height,
    if (replyTo != null) 'replyTo': replyTo.toMap(),
  }, 'GIF');

  /// Voice message (m4a).
  Future<void> sendVoice(
    ChatPerson other,
    File file,
    int durationMs, {
    MessageQuote? replyTo,
  }) async {
    final up = await MediaService.instance.upload(file, kind: MediaKind.voice);
    await _write(other, {
      'kind': Message.voice,
      'text': '',
      'mediaUrl': up.url,
      'mediaKey': up.key,
      'durationMs': durationMs,
      if (replyTo != null) 'replyTo': replyTo.toMap(),
    }, '🎤 Voice message');
  }

  /// Where you are (not live): card with the address, opens Google Maps.
  Future<void> sendLocation(
    ChatPerson other, {
    required double lat,
    required double lng,
    String address = '',
    MessageQuote? replyTo,
  }) {
    final a = address.length > 300 ? address.substring(0, 300) : address;
    return _write(other, {
      'kind': Message.location,
      'text': '',
      'lat': lat,
      'lng': lng,
      'address': a,
      if (replyTo != null) 'replyTo': replyTo.toMap(),
    }, '📍 ${a.isEmpty ? 'Location' : a}');
  }

  /// Sends a copy of [m] to [to] (marked "Forwarded").
  Future<void> forward(Message m, ChatPerson to) =>
      _write(to, forwardFields(m), m.preview);

  /// Fields of a forwarded copy (no reactions / reply / owner).
  static Map<String, dynamic> forwardFields(Message m) => {
    'kind': m.kind,
    'text': m.text,
    'forwarded': true,
    if (m.isSharedPost) ...{
      'postId': m.postId,
      'postType': m.postType,
      'postThumb': m.postThumb,
      'postAuthor': m.postAuthor,
      'postCaption': m.postCaption,
    },
    if (m.mediaUrl.isNotEmpty) 'mediaUrl': m.mediaUrl,
    // the copy never owns the file (deleting it must not break this one)
    if (m.width > 0) 'width': m.width,
    if (m.height > 0) 'height': m.height,
    if (m.durationMs > 0) 'durationMs': m.durationMs,
    if (m.isLocation) ...{'lat': m.lat, 'lng': m.lng, 'address': m.address},
  };

  DocumentReference<Map<String, dynamic>> _msg(String chatId, String id) =>
      _chats.doc(chatId).collection('messages').doc(id);

  /// Your emoji on a message (null = remove yours).
  Future<void> react(String chatId, String messageId, String? emoji) => _msg(
    chatId,
    messageId,
  ).update({'reactions.$myUid': emoji ?? FieldValue.delete()});

  /// "Delete for you": only you stop seeing it.
  Future<void> hideForMe(String chatId, String messageId) =>
      _msg(chatId, messageId).update({
        'hiddenFor': FieldValue.arrayUnion([myUid]),
      });

  /// "Delete for everyone" (only your own messages).
  Future<void> deleteForEveryone(String chatId, Message m) async {
    await _msg(chatId, m.id).delete();
    if (m.mediaKey.isNotEmpty) {
      MediaService.instance.delete(m.mediaKey).ignore();
    }
    try {
      final chatRef = _chats.doc(chatId);
      final chat = await chatRef.get();
      final pinned = chat.data()?['pinned'];
      final last = await chatRef
          .collection('messages')
          .orderBy('createdAt', descending: true)
          .limit(1)
          .get();
      final next = last.docs.isEmpty ? null : Message.fromDoc(last.docs.first);
      final preview = next?.preview ?? '';
      await chatRef.update({
        'lastMessage': preview.length > 200
            ? preview.substring(0, 200)
            : preview,
        'lastSenderId': next?.senderId ?? '',
        if (pinned is Map && pinned['id'] == m.id)
          'pinned': FieldValue.delete(),
      });
    } catch (_) {} // the message is gone; the list text can wait
  }

  /// Pins [m] at the top of the chat (one at a time).
  Future<void> pin(String chatId, Message m) {
    final t = m.preview;
    return _chats.doc(chatId).update({
      'pinned': {'id': m.id, 'text': t.length > 120 ? t.substring(0, 120) : t},
    });
  }

  Future<void> unpin(String chatId) =>
      _chats.doc(chatId).update({'pinned': FieldValue.delete()});

  /// Sends a post / clip into the chat (shown as a card that opens it).
  Future<void> sendPost(ChatPerson other, Post post) {
    final what = post.isClip ? 'clip' : 'post';
    final text = 'Shared a $what by @${post.authorUsername}';
    return _write(other, {
      'text': text,
      'postId': post.id,
      'postType': post.type,
      'postThumb': post.coverUrl,
      'postAuthor': post.authorUsername,
      'postCaption': post.caption.length > 120
          ? post.caption.substring(0, 120)
          : post.caption,
    }, text);
  }

  // ------------------------------------------------- v0.11 disappearing

  /// Disappearing mode of each chat (kept fresh by the open chat screen).
  final Map<String, String> _modes = {};

  void rememberMode(String chatId, String mode) => _modes[chatId] = mode;

  Future<String> _modeOf(String chatId) async {
    final known = _modes[chatId];
    if (known != null) return known;
    try {
      final d = await _chats.doc(chatId).get();
      return _modes[chatId] = Disappear.normalize(d.data()?['disappear']);
    } catch (_) {
      return Disappear.off;
    }
  }

  /// Extra fields for a new message in a chat with [mode].
  static Map<String, dynamic> disappearFields(String mode, DateTime now) {
    if (mode == Disappear.seen) return {'vanish': true};
    final life = Disappear.lifetime(mode);
    if (life == null) return const {};
    return {'expireAt': Timestamp.fromDate(now.add(life))};
  }

  /// Turns disappearing messages on / off (both people see the change).
  Future<void> setDisappear(ChatPerson other, String mode) async {
    final m = Disappear.normalize(mode);
    final me = await UserRepository.instance.me();
    final text = '${me.username} ${Disappear.sentence(m)}';
    _modes[chatIdWith(other.uid)] = m;
    await _write(
      other,
      {'kind': Message.system, 'text': text},
      m == Disappear.off ? 'Disappearing messages off' : '⏳ Disappearing messages on',
      chat: {'disappear': m},
      push: false,
    );
  }

  /// v0.11 call log: "Voice call · 2:31" / "Missed video call" in the chat.
  /// Written by the caller when the call is over.
  Future<void> addCallLog(
    ChatPerson other, {
    required bool video,
    required String status,
    required int durationSec,
  }) {
    final m = Message(
      id: '',
      senderId: '',
      text: '',
      createdAt: DateTime.now(),
      kind: Message.call,
      callStatus: status,
      video: video,
      durationSec: durationSec,
    );
    return _write(other, {
      'kind': Message.call,
      'text': '',
      'callStatus': status,
      'video': video,
      'durationSec': durationSec.clamp(0, 86400),
    }, m.preview, push: false);
  }

  /// Messages you should not see: hidden by you, before "Delete chat",
  /// disappeared (time over, or "once seen" ones you saw before).
  static List<Message> visible(
    List<Message> all, {
    required String me,
    DateTime? clearedAt,
    DateTime? seenBefore,
    DateTime? now,
  }) {
    final t = now ?? ServerClock.now();
    return all.where((m) {
      if (m.hiddenForUid(me)) return false;
      if (clearedAt != null && !m.pending && !m.createdAt.isAfter(clearedAt)) {
        return false;
      }
      if (m.expiredAt(t)) return false;
      if (m.vanish &&
          m.senderId != me &&
          seenBefore != null &&
          !m.pending &&
          !m.createdAt.isAfter(seenBefore)) {
        return false;
      }
      return true;
    }).toList();
  }

  /// Removes disappeared messages from the server (either person may).
  /// [seenVanish] = "once seen" messages the other person sent that you saw.
  Future<void> sweep(
    String chatId,
    List<Message> all, {
    Iterable<Message> seenVanish = const [],
  }) async {
    final now = ServerClock.now();
    final gone = <String>{
      for (final m in all)
        if (m.expiredAt(now) && !m.pending) m.id,
      for (final m in seenVanish)
        if (!m.pending) m.id,
    };
    if (gone.isEmpty) return;
    final batch = _db.batch();
    for (final id in gone.take(100)) {
      batch.delete(_msg(chatId, id));
    }
    try {
      await batch.commit();
    } catch (e) {
      debugPrint('sweep: $e');
    }
  }

  /// Saves the message; returns its id. [chat] = extra chat fields.
  Future<String> _write(
    ChatPerson other,
    Map<String, dynamic> message,
    String preview, {
    Map<String, dynamic> chat = const {},
    bool push = true,
  }) async {
    final me = await UserRepository.instance.me();
    final chatId = chatIdWith(other.uid);
    final chatRef = _chats.doc(chatId);
    final members = [me.uid, other.uid]..sort();
    final kind = message['kind'];
    final special = kind == Message.system || kind == Message.call;
    final extra = special
        ? const <String, dynamic>{}
        : disappearFields(await _modeOf(chatId), ServerClock.now());
    // "once seen" messages don't show their text in the chat list
    final shown = extra['vanish'] == true ? '💨 Sent a message' : preview;
    final batch = _db.batch();
    batch.set(chatRef, {
      'members': members,
      'memberInfo': {
        me.uid: {'username': me.username, 'photoUrl': me.photoUrl},
        other.uid: {'username': other.username, 'photoUrl': other.photoUrl},
      },
      'lastMessage': shown.length > 200 ? shown.substring(0, 200) : shown,
      'lastSenderId': me.uid,
      'updatedAt': FieldValue.serverTimestamp(),
      ...chat,
    }, SetOptions(merge: true));
    final ref = chatRef.collection('messages').doc();
    batch.set(ref, {
      ...message,
      ...extra,
      'senderId': me.uid,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
    if (push) unawaited(_notify(chatId, ref.id));
    return ref.id;
  }

  /// v0.11: "username: message" notification on the other phone.
  Future<void> _notify(String chatId, String messageId) async {
    if (debugNoPush) return;
    try {
      await ApiClient.instance.post('/api/message-push', {
        'chatId': chatId,
        'messageId': messageId,
      });
    } catch (e) {
      debugPrint('message push: $e'); // the message is sent anyway
    }
  }

  @visibleForTesting
  static bool debugNoPush = false;

  /// People to share with: recent chats first, then people I follow.
  Future<List<ChatPerson>> shareTargets({int max = 150}) async {
    final me = myUid;
    final out = <String, ChatPerson>{};
    try {
      final chats = await _chats
          .where('members', arrayContains: me)
          .orderBy('updatedAt', descending: true)
          .limit(40)
          .get();
      for (final c in chats.docs.map(Chat.fromDoc)) {
        final o = c.otherUid(me);
        if (o == me) continue;
        out[o] = ChatPerson(
          uid: o,
          username: c.usernameOf(o),
          photoUrl: c.photoOf(o),
          recent: true,
        );
      }
    } catch (_) {}
    try {
      final ids = await UserRepository.instance.followingIds(me).first;
      final missing = ids.where((id) => !out.containsKey(id)).toList();
      final users = await UserRepository.instance.usersByIds(
        missing.take(max).toList(),
      );
      for (final u in users) {
        out[u.uid] = ChatPerson(
          uid: u.uid,
          username: u.username,
          photoUrl: u.photoUrl,
          name: u.name,
        );
      }
    } catch (_) {}
    return out.values.take(max).toList();
  }
}

/// Someone you can send a message / post to.
class ChatPerson {
  const ChatPerson({
    required this.uid,
    required this.username,
    required this.photoUrl,
    this.name = '',
    this.recent = false,
  });
  final String uid;
  final String username;
  final String photoUrl;
  final String name;

  /// You chatted with them recently.
  final bool recent;

  factory ChatPerson.of(UserProfile u) =>
      ChatPerson(uid: u.uid, username: u.username, photoUrl: u.photoUrl);

  bool matches(String q) {
    final w = q.trim().toLowerCase().replaceFirst('@', '');
    return w.isEmpty ||
        username.toLowerCase().contains(w) ||
        name.toLowerCase().contains(w);
  }
}
