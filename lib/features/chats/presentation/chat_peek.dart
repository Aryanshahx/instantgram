import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/models/post.dart';
import '../data/chat_repository.dart';
import '../../../shared/widgets/skeleton.dart';

/// v0.15: read the last messages from the chat list (long-press) WITHOUT
/// opening the chat — nothing is marked as seen, no blue ticks for them.
class ChatPeek extends StatelessWidget {
  const ChatPeek({
    super.key,
    required this.messages,
    required this.me,
    this.clearedAt,
    this.seenBefore,
    this.maxHeight = 240,
  });

  static const int count = 15;

  final Stream<List<Message>> messages;
  final String me;
  final DateTime? clearedAt;
  final DateTime? seenBefore;
  final double maxHeight;

  /// The newest [count] messages you may see, newest first.
  static List<Message> pick(
    List<Message> all, {
    required String me,
    DateTime? clearedAt,
    DateTime? seenBefore,
    DateTime? now,
  }) {
    final list = ChatRepository.visible(
      all,
      me: me,
      clearedAt: clearedAt,
      seenBefore: seenBefore,
      now: now,
    )..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list.length > count ? list.sublist(0, count) : list;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('chat-peek'),
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: StreamBuilder<List<Message>>(
              stream: messages,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const SizedBox(
                    height: 80,
                    child: Skeleton(kind: SkeletonKind.chat, count: 2),
                  );
                }
                final list = pick(
                  snap.data!,
                  me: me,
                  clearedAt: clearedAt,
                  seenBefore: seenBefore,
                );
                if (list.isEmpty) {
                  return const SizedBox(
                    height: 60,
                    child: Center(
                      child: Text(
                        'No messages',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  reverse: true,
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
                  itemCount: list.length,
                  itemBuilder: (context, i) =>
                      _PeekBubble(list[i], mine: list[i].senderId == me),
                );
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.visibility_off_outlined,
                  size: 14,
                  color: AppColors.textSecondary,
                ),
                SizedBox(width: 6),
                Flexible(
                  child: Text(
                    "Preview · they won't know you read it",
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PeekBubble extends StatelessWidget {
  const _PeekBubble(this.m, {required this.mine});
  final Message m;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        constraints: const BoxConstraints(maxWidth: 240),
        decoration: BoxDecoration(
          color: mine ? const Color(0xFF2E3A12) : AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          m.preview,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13.5, height: 1.3),
        ),
      ),
    );
  }
}
