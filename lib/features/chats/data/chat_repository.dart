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
    final me = await UserRepository.instance.me();
    final chatRef = _chats.doc(chatIdWith(other.uid));
    final members = [me.uid, other.uid]..sort();
    final batch = _db.batch();
    batch.set(
      chatRef,
      {
        'members': members,
        'memberInfo': {
          me.uid: {'username': me.username, 'photoUrl': me.photoUrl},
          other.uid: {'username': other.username, 'photoUrl': other.photoUrl},
        },
        'lastMessage': t.length > 200 ? t.substring(0, 200) : t,
        'lastSenderId': me.uid,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    batch.set(chatRef.collection('messages').doc(), {
      'senderId': me.uid,
      'text': t,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }
}
