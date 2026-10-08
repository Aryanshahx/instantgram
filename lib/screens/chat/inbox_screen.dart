import 'dart:async';

import 'package:flutter/material.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../../core/errors.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../models/chat.dart';
import '../../services/chat_service.dart';
import '../../services/presence_service.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/live_presence.dart';
import '../../widgets/state_views.dart';
import 'chat_options_sheet.dart';
import 'chat_peek_sheet.dart';
import 'chat_screen.dart';

/// The Chats tab: your conversations, and a search box to start one with anyone.
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  // Profiles are fetched again after a while, so the "active" dots stay fresh.
  static final Map<String, (DateTime, Future<AppUser?>)> _users = {};
  static Future<AppUser?> _user(String uid) {
    final now = DateTime.now();
    final hit = _users[uid];
    if (hit != null && now.difference(hit.$1) < const Duration(minutes: 2)) {
      return hit.$2;
    }
    final f = UserService.instance.getUser(uid);
    _users[uid] = (now, f);
    return f;
  }

  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';
  bool _searching = false;
  Object? _searchError;
  List<AppUser> _results = [];

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    final q = text.trim();
    setState(() {
      _query = q;
      _searching = q.isNotEmpty;
      _searchError = null;
      if (q.isEmpty) _results = [];
    });
    if (q.isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final me = UserService.instance.myUid;
        final users = (await UserService.instance.searchUsers(
          q,
        )).where((u) => u.uid != me).toList();
        if (!mounted || _query != q) return;
        setState(() {
          _results = users;
          _searching = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _searching = false;
          _searchError = e;
        });
      }
    });
  }

  void _open(AppUser u) {
    openScreen(context, ChatScreen(otherUid: u.uid, user: u));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: ContentWidth(
        maxWidth: 680,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 14, 20, 12),
              child: Text(
                'Chats',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1.2,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                key: const ValueKey('chatSearch'),
                controller: _controller,
                onChanged: _onChanged,
                autocorrect: false,
                decoration: InputDecoration(
                  hintText: 'Find someone to message',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () {
                            _controller.clear();
                            _onChanged('');
                          },
                        ),
                ),
              ),
            ),
            Expanded(child: _query.isEmpty ? _threads() : _people()),
          ],
        ),
      ),
    );
  }

  Widget _people() {
    if (_searching && _results.isEmpty) return const CenteredLoader();
    if (_searchError != null) {
      return ErrorState(
        error: _searchError!,
        onRetry: () => _onChanged(_query),
      );
    }
    if (_results.isEmpty) {
      return EmptyState(
        icon: Icons.person_search_rounded,
        title: 'No one found',
        subtitle: 'Nobody matches "$_query".',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, kNavSpace),
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final u = _results[i];
        return _Row(
          avatarUrl: u.photoUrl,
          name: u.username,
          subtitle: u.fullName,
          onTap: () => _open(u),
        );
      },
    );
  }

  Future<void> _options(
    ChatThread thread,
    String name, {
    VoidCallback? open,
  }) async {
    final pick = await showChatOptions(context, thread: thread, name: name);
    if (pick == null || !mounted) return;
    final service = ChatService.instance;
    switch (pick) {
      case ChatOption.peek:
        await showChatPeek(
          context,
          chatId: thread.id,
          myUid: UserService.instance.myUid,
          name: name,
          onOpenChat: open,
        );
        return;
      case ChatOption.delete:
        final ok = await confirmDeleteChat(
          context,
          name.isEmpty ? 'the other person' : name,
        );
        if (!ok || !mounted) return;
        try {
          await service.deleteChat(thread.id);
          if (mounted) showToast(context, 'Chat deleted');
        } catch (e) {
          if (mounted) showToast(context, friendlyError(e));
        }
        return;
      case ChatOption.pin:
        await _flag(
          thread,
          pinned: !thread.pinned,
          done: thread.pinned ? 'Unpinned' : 'Pinned to the top',
        );
        return;
      case ChatOption.muteCalls:
        await _flag(
          thread,
          muteCalls: !thread.muteCalls,
          done: thread.muteCalls ? 'Calls unmuted' : 'Calls muted',
        );
        return;
      case ChatOption.muteMessages:
        await _flag(
          thread,
          muteMessages: !thread.muteMessages,
          done: thread.muteMessages ? 'Messages unmuted' : 'Messages muted',
        );
        return;
    }
  }

  Future<void> _flag(
    ChatThread thread, {
    bool? pinned,
    bool? muteCalls,
    bool? muteMessages,
    required String done,
  }) async {
    try {
      await ChatService.instance.setChatFlags(
        thread.id,
        pinned: pinned,
        muteCalls: muteCalls,
        muteMessages: muteMessages,
      );
      if (mounted) showToast(context, done);
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    }
  }

  Widget _threads() {
    final service = ChatService.instance;
    return ValueListenableBuilder<Object?>(
      valueListenable: service.error,
      builder: (context, err, _) => ValueListenableBuilder<List<ChatThread>>(
        valueListenable: service.threads,
        builder: (context, threads, _) {
          if (err != null && threads.isEmpty) {
            return ErrorState(
              error: err,
              onRetry: () {
                service.stop();
                service.start();
              },
            );
          }
          if (threads.isEmpty) {
            return const EmptyState(
              icon: Icons.chat_bubble_outline_rounded,
              title: 'No messages yet',
              subtitle:
                  'Search for someone above, or open anyone\'s profile and tap Message.',
            );
          }
          final me = UserService.instance.myUid;
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, kNavSpace),
            itemCount: threads.length,
            itemBuilder: (context, i) {
              final t = threads[i];
              final otherUid = t.other(me);
              return FutureBuilder<AppUser?>(
                future: _user(otherUid),
                builder: (context, snap) {
                  final u = snap.data;
                  final gone =
                      snap.connectionState == ConnectionState.done &&
                      !snap.hasError &&
                      u == null;
                  final unread = t.isUnread(me);
                  final mine = t.lastSender == me;
                  return LivePresence(
                    key: ValueKey('presence_$otherUid'),
                    uid: otherUid,
                    initial: u,
                    builder: (context, live) => _Row(
                      uid: gone ? null : otherUid,
                      avatarUrl: u?.photoUrl ?? '',
                      name: gone ? kUserNotAvailable : (u?.username ?? '...'),
                      subtitle: mine
                          ? '${t.seenByOther(me) ? 'Seen' : 'Sent'} · You: ${t.lastText}'
                          : t.lastText,
                      time: t.lastAt == null
                          ? ''
                          : timeago.format(t.lastAt!, locale: 'en_short'),
                      unread: unread,
                      online:
                          !gone &&
                          isActiveNow(
                            (live ?? u)?.lastActive,
                            DateTime.now(),
                            online: (live ?? u)?.online ?? true,
                          ),
                      onTap: () => openScreen(
                        context,
                        ChatScreen(otherUid: otherUid, user: u),
                      ),
                      onLongPress: () => _options(
                        t,
                        u?.username ?? '',
                        open: () => openScreen(
                          context,
                          ChatScreen(otherUid: otherUid, user: u),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.avatarUrl,
    this.uid,
    required this.name,
    required this.subtitle,
    required this.onTap,
    this.time = '',
    this.unread = false,
    this.online = false,
    this.onLongPress,
  });

  final String avatarUrl;
  final String? uid;
  final String name;
  final String subtitle;
  final String time;
  final bool unread;

  /// Shows a green dot: they have the app open right now.
  final bool online;
  final VoidCallback onTap;

  /// Holding the row opens the chat options.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: context.card,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: context.hairline.withValues(alpha: 0.7)),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        contentPadding: const EdgeInsets.fromLTRB(10, 6, 14, 6),
        leading: Stack(
          clipBehavior: Clip.none,
          children: [
            UserAvatar(url: avatarUrl, name: name, radius: 25, uid: uid),
            if (online)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  key: const ValueKey('activeDot'),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2ECC71),
                    shape: BoxShape.circle,
                    border: Border.all(color: context.card, width: 2.5),
                  ),
                ),
              ),
          ],
        ),
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: unread ? FontWeight.w900 : FontWeight.w800,
          ),
        ),
        subtitle: subtitle.isEmpty
            ? null
            : Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: unread
                      ? Theme.of(context).colorScheme.onSurface
                      : context.muted,
                  fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (time.isNotEmpty)
              Text(time, style: TextStyle(color: context.muted, fontSize: 12)),
            if (unread) ...[
              const SizedBox(height: 6),
              Container(
                key: const ValueKey('unreadDot'),
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: AppTheme.volt,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}
