import 'dart:async';

import 'package:flutter/material.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../models/chat.dart';
import '../../services/chat_service.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/state_views.dart';
import 'chat_screen.dart';

/// The Chats tab: your conversations, and a search box to start one with anyone.
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  static final Map<String, Future<AppUser?>> _users = {};
  static Future<AppUser?> _user(String uid) =>
      _users.putIfAbsent(uid, () => UserService.instance.getUser(uid));

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
                  final unread = t.isUnread(me);
                  final mine = t.lastSender == me;
                  return _Row(
                    uid: otherUid,
                    avatarUrl: u?.photoUrl ?? '',
                    name: u?.username ?? '...',
                    subtitle: '${mine ? 'You: ' : ''}${t.lastText}',
                    time: t.lastAt == null
                        ? ''
                        : timeago.format(t.lastAt!, locale: 'en_short'),
                    unread: unread,
                    onTap: () => openScreen(
                      context,
                      ChatScreen(otherUid: otherUid, user: u),
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
  });

  final String avatarUrl;
  final String? uid;
  final String name;
  final String subtitle;
  final String time;
  final bool unread;
  final VoidCallback onTap;

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
        leading: UserAvatar(
          url: avatarUrl,
          name: name,
          radius: 25,
          uid: uid,
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
      ),
    );
  }
}
