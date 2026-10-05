import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../models/chat.dart';

enum MessageAction {
  reply,
  forward,
  copy,
  pin,
  unpin,
  deleteForMe,
  deleteForAll,
}

/// What was picked in the message menu: an action or a reaction emoji.
class MessageChoice {
  const MessageChoice.action(this.action) : emoji = null;
  const MessageChoice.react(this.emoji) : action = null;
  final MessageAction? action;
  final String? emoji;
}

/// The menu that opens when a message is held: reactions on top, then the actions.
Future<MessageChoice?> showMessageMenu(
  BuildContext context, {
  required ChatMessage message,
  required bool mine,
  required String myUid,
}) {
  return showModalBottomSheet<MessageChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => _MessageMenu(message: message, mine: mine, myUid: myUid),
  );
}

class _MessageMenu extends StatelessWidget {
  const _MessageMenu({
    required this.message,
    required this.mine,
    required this.myUid,
  });

  final ChatMessage message;
  final bool mine;
  final String myUid;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final deleted = m.deleted;
    final mineReaction = m.reactions[myUid];

    Widget tile(
      IconData icon,
      String label,
      MessageAction a, {
      bool danger = false,
    }) => ListTile(
      key: ValueKey('action_${a.name}'),
      leading: Icon(icon, color: danger ? AppTheme.coral : null),
      title: Text(
        label,
        style: TextStyle(color: danger ? AppTheme.coral : null),
      ),
      onTap: () => Navigator.pop(context, MessageChoice.action(a)),
    );

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!deleted)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final e in kReactions)
                    GestureDetector(
                      key: ValueKey('pick_$e'),
                      onTap: () =>
                          Navigator.pop(context, MessageChoice.react(e)),
                      child: Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: e == mineReaction
                              ? AppTheme.volt.withValues(alpha: 0.3)
                              : context.softFill,
                          shape: BoxShape.circle,
                        ),
                        child: Text(e, style: const TextStyle(fontSize: 22)),
                      ),
                    ),
                ],
              ),
            ),
          if (!deleted) tile(Icons.reply_rounded, 'Reply', MessageAction.reply),
          if (!deleted)
            tile(Icons.shortcut_rounded, 'Forward', MessageAction.forward),
          if (!deleted && m.type == MsgType.text && m.text.isNotEmpty)
            tile(Icons.copy_rounded, 'Copy', MessageAction.copy),
          if (!deleted)
            m.pinned
                ? tile(Icons.push_pin_outlined, 'Unpin', MessageAction.unpin)
                : tile(Icons.push_pin_rounded, 'Pin to top', MessageAction.pin),
          tile(
            Icons.delete_outline_rounded,
            'Delete for me',
            MessageAction.deleteForMe,
          ),
          if (mine && !deleted)
            tile(
              Icons.delete_forever_rounded,
              'Delete for everyone',
              MessageAction.deleteForAll,
              danger: true,
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Copies a text message.
Future<void> copyMessage(ChatMessage m) =>
    Clipboard.setData(ClipboardData(text: m.text));
