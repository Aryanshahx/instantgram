import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/ig_text_field.dart';
import '../../../shared/widgets/user_tile.dart';
import '../../profile/data/user_repository.dart';
import '../data/chat_repository.dart';
import 'chat_detail_screen.dart';

void openChat(BuildContext context, UserProfile other) {
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => ChatDetailScreen(other: other)),
  );
}

class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  final Stream<List<Chat>> _chats = ChatRepository.instance.myChats();
  Timer? _debounce;
  String _query = '';
  List<UserProfile> _people = const [];

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String v) {
    final q = v.trim();
    setState(() => _query = q);
    _debounce?.cancel();
    if (q.isEmpty) {
      setState(() => _people = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final res = await UserRepository.instance.search(q);
        final me = UserRepository.instance.myUid;
        if (mounted && _query == q) {
          setState(() => _people = res.where((u) => u.uid != me).toList());
        }
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final me = UserRepository.instance.myUid;
    return SafeArea(
      bottom: false,
      child: StreamBuilder<List<Chat>>(
        stream: _chats,
        builder: (context, snap) {
          final q = _query.toLowerCase();
          final chats = (snap.data ?? const <Chat>[])
              .where((c) =>
                  q.isEmpty ||
                  c.usernameOf(c.otherUid(me)).toLowerCase().contains(q))
              .toList();

          return ListView(
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
                onChanged: _onChanged,
              ),
              const SizedBox(height: 14),
              if (snap.hasError)
                ErrorView(error: snap.error)
              else if (!snap.hasData)
                const LoadingView()
              else ...[
                for (final c in chats)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _ChatTile(
                      chat: c,
                      me: me,
                      onTap: () {
                        final other = c.otherUid(me);
                        openChat(
                          context,
                          UserProfile(
                            uid: other,
                            name: '',
                            username: c.usernameOf(other),
                            photoUrl: c.photoOf(other),
                          ),
                        );
                      },
                    ),
                  ),
                if (_people.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(4, 8, 4, 4),
                    child: Text(
                      'Start a new chat',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                  ),
                  for (final u in _people)
                    UserTile(
                      user: u,
                      onTap: () => openChat(context, u),
                      trailing: const Icon(Icons.send_rounded,
                          color: AppColors.lime),
                    ),
                ],
                if (chats.isEmpty && _people.isEmpty)
                  EmptyState(
                    icon: Icons.chat_bubble_outline,
                    title: q.isEmpty ? 'No chats yet' : 'Nobody found',
                    subtitle: q.isEmpty
                        ? 'Search a username above to send a message.'
                        : 'Try another username.',
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({required this.chat, required this.me, required this.onTap});

  final Chat chat;
  final String me;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final other = chat.otherUid(me);
    final name = chat.usernameOf(other);
    final fromMe = chat.lastSenderId == me;
    final preview = chat.lastMessage.isEmpty
        ? 'Say hi 👋'
        : fromMe
            ? 'Sent · You: ${chat.lastMessage}'
            : chat.lastMessage;

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
              Avatar(url: chat.photoOf(other), name: name, size: 58),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
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
                      style: TextStyle(
                        fontSize: 15,
                        color: fromMe
                            ? AppColors.textSecondary
                            : AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                timeAgo(chat.updatedAt, approx: true),
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
