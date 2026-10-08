import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/chat.dart';
import '../../services/chat_service.dart';
import '../../widgets/message_bubble.dart';

/// Tests replace the message stream.
Stream<List<ChatMessage>> Function(String chatId)? debugPeekMessages;

/// Reads a chat without opening it: the other person does not get "Seen", and
/// "after seen" messages are not used up. "Open chat" opens it normally.
Future<void> showChatPeek(
  BuildContext context, {
  required String chatId,
  required String myUid,
  String name = '',
  VoidCallback? onOpenChat,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: Theme.of(context).scaffoldBackgroundColor,
  builder: (ctx) => FractionallySizedBox(
    heightFactor: 0.75,
    child: _PeekSheet(
      chatId: chatId,
      myUid: myUid,
      name: name,
      onOpenChat: onOpenChat == null
          ? null
          : () {
              Navigator.of(ctx).pop();
              onOpenChat();
            },
    ),
  ),
);

class _PeekSheet extends StatelessWidget {
  const _PeekSheet({
    required this.chatId,
    required this.myUid,
    required this.name,
    this.onOpenChat,
  });

  final String chatId;
  final String myUid;
  final String name;
  final VoidCallback? onOpenChat;

  @override
  Widget build(BuildContext context) {
    final stream = (debugPeekMessages ?? ChatService.instance.watchMessages)(
      chatId,
    );
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(
              name.isEmpty ? 'Peek' : name,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.visibility_off_outlined,
                size: 15,
                color: context.muted,
              ),
              const SizedBox(width: 6),
              Text(
                "Peeking: they won't see Seen",
                key: const ValueKey('peekNote'),
                style: TextStyle(color: context.muted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: StreamBuilder<List<ChatMessage>>(
              stream: stream,
              builder: (context, snap) {
                if (snap.hasError) {
                  return const Center(
                    child: Text('Could not load the messages.'),
                  );
                }
                final all = snap.data;
                if (all == null) {
                  return const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  );
                }
                final now = DateTime.now();
                final msgs = [
                  for (final m in all.take(60))
                    if (m.visibleFor(myUid) && !m.expired(now)) m,
                ];
                if (msgs.isEmpty) {
                  return Center(
                    child: Text(
                      'No messages',
                      style: TextStyle(color: context.muted),
                    ),
                  );
                }
                // read only: no menus, reactions or replies
                return ListView.builder(
                  key: const ValueKey('peekList'),
                  reverse: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) {
                    final m = msgs[i];
                    if (m.type == MsgType.system) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 24,
                        ),
                        child: Text(
                          m.text,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: context.muted, fontSize: 12),
                        ),
                      );
                    }
                    return MessageBubble(
                      message: m,
                      text: m.text,
                      mine: m.senderId == myUid,
                      myUid: myUid,
                      time: chatTime(m.createdAt),
                    );
                  },
                );
              },
            ),
          ),
          if (onOpenChat != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const ValueKey('peekOpen'),
                  onPressed: onOpenChat,
                  icon: const Icon(Icons.chat_bubble_outline_rounded),
                  label: const Text('Open chat (marks as seen)'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
