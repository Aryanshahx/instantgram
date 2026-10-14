import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/painting.dart' show decodeImageFromList;

import '../../../core/services/gif_search.dart';
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

  Future<void> _write(
    ChatPerson other,
    Map<String, dynamic> message,
    String preview,
  ) async {
    final me = await UserRepository.instance.me();
    final chatRef = _chats.doc(chatIdWith(other.uid));
    final members = [me.uid, other.uid]..sort();
    final batch = _db.batch();
    batch.set(chatRef, {
      'members': members,
      'memberInfo': {
        me.uid: {'username': me.username, 'photoUrl': me.photoUrl},
        other.uid: {'username': other.username, 'photoUrl': other.photoUrl},
      },
      'lastMessage': preview.length > 200 ? preview.substring(0, 200) : preview,
      'lastSenderId': me.uid,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    batch.set(chatRef.collection('messages').doc(), {
      ...message,
      'senderId': me.uid,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }

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
