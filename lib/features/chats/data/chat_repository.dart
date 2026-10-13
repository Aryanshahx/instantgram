import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

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

  Stream<List<Message>> messages(String chatId) => _chats
      .doc(chatId)
      .collection('messages')
      .orderBy('createdAt', descending: true)
      .limit(200)
      .snapshots()
      .map((s) => s.docs.map(Message.fromDoc).toList());

  Future<void> send(UserProfile other, String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _write(
      ChatPerson(
        uid: other.uid,
        username: other.username,
        photoUrl: other.photoUrl,
      ),
      {'text': t},
      t,
    );
  }

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

  bool matches(String q) {
    final w = q.trim().toLowerCase().replaceFirst('@', '');
    return w.isEmpty ||
        username.toLowerCase().contains(w) ||
        name.toLowerCase().contains(w);
  }
}
