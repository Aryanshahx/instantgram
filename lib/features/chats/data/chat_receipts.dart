import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../shared/models/post.dart';
import 'channel_topics.dart';
import 'chat_repository.dart';

/// v0.10: tells the sender "delivered" (✓✓ grey) as soon as new messages
/// reach this phone, even if you don't open the chat. Runs while the app
/// is open (from the main screen).
class ChatReceipts {
  ChatReceipts._();
  static final ChatReceipts instance = ChatReceipts._();

  StreamSubscription<List<Chat>>? _sub;
  final Map<String, DateTime> _done = {};

  void start(String uid) {
    _sub?.cancel();
    _sub = ChatRepository.instance.myChats().listen(
      (chats) {
        check(uid, chats, ChatRepository.instance.markDelivered);
        // v0.0.2: pushes for the channels you follow
        ChannelTopics.instance.update(uid, chats);
      },
      onError: (Object e) => debugPrint('receipts: $e'),
    );
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _done.clear();
  }

  /// Marks every chat with a newer message from the other person.
  @visibleForTesting
  void check(
    String me,
    List<Chat> chats,
    Future<void> Function(String chatId) mark,
  ) {
    for (final c in chats) {
      if (c.lastSenderId.isEmpty || c.lastSenderId == me) continue;
      if (c.isChannel) continue; // v0.0.2: no ticks in channels
      final d = c.deliveredAt(me);
      if (d != null && !d.isBefore(c.updatedAt)) continue;
      if (_done[c.id] == c.updatedAt) continue; // already asked
      _done[c.id] = c.updatedAt;
      mark(c.id).catchError((Object e) {
        debugPrint('delivered: $e');
      });
    }
  }
}
