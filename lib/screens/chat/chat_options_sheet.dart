import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/chat.dart';

/// What you can do with a chat when you hold it.
enum ChatOption { peek, delete, pin, muteCalls, muteMessages }

/// Holding a chat in the inbox: delete it, keep it on top, or quieten it.
///
/// The sheet only says what was picked; the screen around it does the work, so this stays
/// easy to test.
Future<ChatOption?> showChatOptions(
  BuildContext context, {
  required ChatThread thread,
  String name = '',
}) {
  final title = name.isEmpty ? 'Conversation' : name;
  return showModalBottomSheet<ChatOption>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    builder: (ctx) {
      Widget tile(
        Key key,
        IconData icon,
        String label,
        ChatOption value, {
        bool on = false,
        bool danger = false,
      }) => ListTile(
        key: key,
        leading: Icon(icon, color: danger ? AppTheme.coral : null),
        title: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: danger ? AppTheme.coral : null,
          ),
        ),
        trailing: on
            ? Icon(Icons.check_rounded, color: context.accentInk)
            : null,
        onTap: () => Navigator.of(ctx).pop(value),
      );
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              tile(
                const ValueKey('chatPeek'),
                Icons.visibility_outlined,
                'Peek (no "Seen")',
                ChatOption.peek,
              ),
              tile(
                const ValueKey('chatPin'),
                thread.pinned
                    ? Icons.push_pin_rounded
                    : Icons.push_pin_outlined,
                thread.pinned ? 'Unpin' : 'Pin to the top',
                ChatOption.pin,
                on: thread.pinned,
              ),
              tile(
                const ValueKey('chatMuteCalls'),
                thread.muteCalls ? Icons.call_end_rounded : Icons.call_rounded,
                thread.muteCalls ? 'Unmute calls' : 'Mute calls',
                ChatOption.muteCalls,
                on: thread.muteCalls,
              ),
              tile(
                const ValueKey('chatMuteMessages'),
                thread.muteMessages
                    ? Icons.notifications_off_rounded
                    : Icons.notifications_rounded,
                thread.muteMessages ? 'Unmute messages' : 'Mute messages',
                ChatOption.muteMessages,
                on: thread.muteMessages,
              ),
              tile(
                const ValueKey('chatDelete'),
                Icons.delete_outline_rounded,
                'Delete chat',
                ChatOption.delete,
                danger: true,
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      );
    },
  );
}

/// Confirms that the whole conversation goes away (for you and for the other person).
Future<bool> confirmDeleteChat(BuildContext context, String name) async {
  return confirm(
    context,
    title: 'Delete this chat?',
    message:
        'Every message of this conversation is removed for you and for $name. '
        'This cannot be undone.',
    confirmLabel: 'Delete',
    destructive: true,
  );
}
