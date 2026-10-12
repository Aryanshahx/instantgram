import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/data/mock_data.dart';
import '../../../shared/models/chat.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/ig_text_field.dart';
import 'chat_detail_screen.dart';

class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final threads = MockData.chats
        .where((t) => q.isEmpty || t.name.toLowerCase().contains(q))
        .toList();

    return SafeArea(
      bottom: false,
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(18, 28, 18, 110),
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 2),
            child: Text('Chats', style: AppTheme.screenTitle),
          ),
          const SizedBox(height: 22),
          IgTextField(
            hint: 'Find someone to message',
            icon: Icons.search,
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 14),
          if (threads.isEmpty)
            const EmptyState(
              icon: Icons.chat_bubble_outline,
              title: 'No chats found',
              subtitle: 'Start a conversation from someone\'s profile.',
            ),
          for (final t in threads)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _ChatTile(
                thread: t,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ChatDetailScreen(thread: t),
                    ),
                  );
                  if (mounted) setState(() {}); // refresh last message
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({required this.thread, required this.onTap});

  final ChatThread thread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final last = thread.last;
    final preview = last == null
        ? 'Say hi 👋'
        : last.fromMe
        ? 'Sent · You: ${last.text}'
        : last.text;

    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 18, 14),
          child: Row(
            children: [
              Avatar(url: thread.avatarUrl, name: thread.name, size: 58),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      thread.name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (last != null)
                Text(
                  timeAgo(last.sentAt, approx: true),
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
