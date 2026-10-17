import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/services/chat_prefs.dart';
import '../../../core/services/content_filter.dart';
import '../../../core/services/server_clock.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/widgets/active_status.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/ig_text_field.dart';
import '../../../shared/widgets/user_tile.dart';
import '../../profile/data/user_repository.dart';
import '../data/chat_repository.dart';
import 'chat_detail_screen.dart';
import 'chat_peek.dart';
import '../data/typing_tracker.dart';
import '../data/channel_seen.dart';
import 'group_screens.dart';
import 'group_widgets.dart';
import '../../../shared/widgets/verified_badge.dart';

void openChat(BuildContext context, UserProfile other) {
  Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => ChatDetailScreen(other: other)));
}

class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key, this.chats, this.myUid, this.previewMessages});

  /// Tests.
  final Stream<List<Chat>>? chats;
  final String? myUid;

  /// Tests: messages for the long-press preview (v0.15).
  final Stream<List<Message>> Function(String chatId)? previewMessages;

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  late final Stream<List<Chat>> _chats =
      widget.chats ?? ChatRepository.instance.myChats();
  Timer? _debounce;
  String _query = '';
  List<UserProfile> _people = const [];
  Timer? _typingTick;

  @override
  void initState() {
    super.initState();
    ChannelSeen.instance.load(); // v0.0.2: unread dots of channels
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _typingTick?.cancel();
    super.dispose();
  }

  /// v0.14: redraw when a "typing…" should go away.
  void _armTyping(List<Chat> chats, String me) {
    Duration? soonest;
    for (final c in chats) {
      // v0.0.2: groups can have several people typing
      final who = c.isMulti
          ? c.typing.keys.where((u) => u != me).toList()
          : [c.otherUid(me)];
      for (final other in who) {
        if (c.typing[other] == null) continue;
        final left = TypingTracker.instance.left(c, other);
        if (left != null && (soonest == null || left < soonest)) {
          soonest = left;
        }
      }
    }
    _typingTick?.cancel();
    _typingTick = null;
    if (soonest == null) return;
    _typingTick = Timer(soonest + const Duration(milliseconds: 50), () {
      if (mounted) setState(() {});
    });
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

  /// v0.11: long-press a chat = pin, mute messages, mute calls, delete.
  Future<void> _menu(Chat c, String me) async {
    final prefs = ChatPrefs.instance;
    final p = prefs.value.value;
    final other = c.otherUid(me);
    final name = c.isMulti ? c.name : c.usernameOf(other);
    final pinned = p.isPinned(c.id);
    final muted = p.isMuted(c.id);
    final calls = p.callsMuted(other);
    // v0.15: peek at the messages (no "seen")
    final peek =
        widget.previewMessages ??
        (widget.chats == null ? ChatRepository.instance.messages : null);
    final h = MediaQuery.of(context).size.height;
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (peek != null)
                ChatPeek(
                  messages: peek(c.id),
                  me: me,
                  clearedAt: p.clearedAt(c.id),
                  seenBefore: c.seenAt(me),
                  maxHeight: (h * 0.32).clamp(140.0, 280.0),
                ),
              _MenuItem(
                id: 'pin',
                icon: pinned ? Icons.push_pin_outlined : Icons.push_pin,
                label: pinned ? 'Unpin chat' : 'Pin chat',
              ),
              _MenuItem(
                id: 'mute',
                icon: muted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
                label: muted ? 'Unmute messages' : 'Mute messages',
              ),
              if (!c.isMulti)
              _MenuItem(
                id: 'calls',
                icon: calls
                    ? Icons.phone_in_talk_outlined
                    : Icons.phone_disabled_outlined,
                label: calls ? 'Unmute calls' : 'Mute calls',
              ),
              const _MenuItem(
                id: 'delete',
                icon: Icons.delete_outline,
                label: 'Delete chat',
                danger: true,
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    final messenger = ScaffoldMessenger.of(context);
    void say(String t) => messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t)));
    try {
      switch (choice) {
        case 'pin':
          final ok = await prefs.togglePin(c.id);
          if (!ok) say('You can pin up to ${ChatPrefs.maxPinned} chats');
        case 'mute':
          await prefs.toggleMuteChat(c.id);
          say(muted ? 'Messages unmuted' : 'Messages from $name muted');
        case 'calls':
          await prefs.toggleMuteCalls(other);
          say(calls ? 'Calls unmuted' : 'Calls from $name will not ring');
        case 'delete':
          final yes = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Delete chat?'),
              content: Text(
                c.isMulti
                    ? '$name is removed from your list. New messages will '
                          'show up again. To stop them, open it and leave.'
                    : 'The chat with $name is removed for you only. New '
                          'messages will show up again.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  key: const ValueKey('chat-delete-yes'),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text(
                    'Delete',
                    style: TextStyle(color: AppColors.like),
                  ),
                ),
              ],
            ),
          );
          if (yes == true) {
            await prefs.deleteChat(c.id);
            say('Chat deleted');
          }
      }
    } catch (e) {
      say('Could not save. Check your internet.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.myUid ?? UserRepository.instance.myUid;
    return SafeArea(
      bottom: false,
      child: ValueListenableBuilder<ChatPrefsData>(
        valueListenable: ChatPrefs.instance.value,
        builder: (context, prefs, _) => StreamBuilder<List<Chat>>(
          stream: _chats,
          builder: (context, snap) {
            final q = _query.toLowerCase();
            final chats = ChatPrefs.sortChats<Chat>(
              (snap.data ?? const <Chat>[])
                  .where(
                    (c) =>
                        (c.isMulti ||
                            !ContentFilter.instance.isBlocked(c.otherUid(me))) &&
                        (q.isEmpty ||
                            (c.isMulti ? c.name : c.usernameOf(c.otherUid(me)))
                                .toLowerCase()
                                .contains(q)),
                  )
                  .toList(),
              prefs,
              id: (c) => c.id,
              updatedAt: (c) => c.updatedAt,
            );
            // after the tiles are built (they mark who is typing)
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _armTyping(chats, me);
            });

            return ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 110),
              children: [
                Row(
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(left: 2),
                      child: Text('Chats', style: AppTheme.pageTitle),
                    ),
                    const Spacer(),
                    // v0.0.2: new group / channel, find channels
                    IconButton(
                      key: const ValueKey('chats-new'),
                      tooltip: 'New group or channel',
                      onPressed: () => showNewChatMenu(context),
                      icon: const Icon(Icons.add_circle_outline, size: 26),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                IgTextField(
                  hint: 'Find someone to message',
                  icon: Icons.search,
                  height: 46,
                  onChanged: _onChanged,
                ),
                const SizedBox(height: 12),
                if (snap.hasError)
                  ErrorView(error: snap.error)
                else if (!snap.hasData)
                  const LoadingView()
                else ...[
                  for (final c in chats)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _ChatTile(
                        key: ValueKey('chat-${c.id}'),
                        chat: c,
                        me: me,
                        pinned: prefs.isPinned(c.id),
                        muted: prefs.isMuted(c.id),
                        callsMuted:
                            !c.isMulti && prefs.callsMuted(c.otherUid(me)),
                        onLongPress: () => _menu(c, me),
                        onTap: () {
                          if (c.isMulti) {
                            openGroupChat(
                              context,
                              c.id,
                              name: c.name,
                              photoUrl: c.photoUrl,
                            );
                            return;
                          }
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
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    for (final u in _people)
                      UserTile(
                        user: u,
                        onTap: () => openChat(context, u),
                        trailing: const Icon(
                          Icons.send_rounded,
                          size: 20,
                          color: AppColors.lime,
                        ),
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
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.id,
    required this.icon,
    required this.label,
    this.danger = false,
  });
  final String id;
  final IconData icon;
  final String label;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.like : AppColors.textPrimary;
    return ListTile(
      key: ValueKey('chat-menu-$id'),
      dense: true,
      leading: Icon(icon, color: color, size: 22),
      title: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          fontFamily: AppTheme.fontFamily,
        ),
      ),
      onTap: () => Navigator.pop(context, id),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({
    super.key,
    required this.chat,
    required this.me,
    required this.onTap,
    this.onLongPress,
    this.pinned = false,
    this.muted = false,
    this.callsMuted = false,
  });

  final Chat chat;
  final String me;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool pinned;
  final bool muted;
  final bool callsMuted;

  /// v0.0.2: tile of a group / channel.
  Widget _groupTile(BuildContext context) {
    final c = chat;
    final fromMe = c.lastSenderId == me;
    final unread = c.isChannel
        ? ChannelSeen.instance.unread(c, me)
        : c.unreadFor(me);
    final now = ServerClock.now();
    final typers = [
      for (final u in c.typing.keys)
        if (u != me && TypingTracker.instance.isTyping(c, u, serverNow: now))
          c.usernameOf(u),
    ];
    final typing = typers.isNotEmpty;
    // system lines ("alice created the group") and channel posts: no name
    final who = c.lastSenderName.isEmpty
        ? ''
        : fromMe
        ? 'You: '
        : '${c.lastSenderName}: ';
    final preview = typing
        ? groupTypingText(typers)
        : c.lastMessage.isEmpty
        ? memberCountText(c.members.length, channel: c.isChannel)
        : '$who${c.lastMessage}';
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
          child: Row(
            children: [
              GroupAvatar(url: c.photoUrl, channel: c.isChannel, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (c.isChannel)
                          const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.campaign_outlined,
                              size: 15,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        Flexible(
                          child: Text(
                            c.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (muted)
                          const Padding(
                            padding: EdgeInsets.only(left: 5),
                            child: Icon(
                              Icons.notifications_off_outlined,
                              key: ValueKey('chat-muted-icon'),
                              size: 14,
                              color: AppColors.textSecondary,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      preview,
                      key: ValueKey('group-preview-${c.id}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: unread ? FontWeight.w700 : FontWeight.w400,
                        color: typing
                            ? AppColors.lime
                            : fromMe
                            ? AppColors.textSecondary
                            : AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (pinned)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 3),
                      child: Icon(
                        Icons.push_pin,
                        key: ValueKey('chat-pinned-icon'),
                        size: 13,
                        color: AppColors.lime,
                      ),
                    ),
                  Text(
                    timeAgo(c.updatedAt, approx: true),
                    style: TextStyle(
                      color: unread ? AppColors.lime : AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  if (unread)
                    Container(
                      key: const ValueKey('unread-dot'),
                      margin: const EdgeInsets.only(top: 6),
                      width: 9,
                      height: 9,
                      decoration: const BoxDecoration(
                        color: AppColors.lime,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (chat.isMulti) {
      // channels: unread dots come from this phone
      return ValueListenableBuilder<Map<String, int>>(
        valueListenable: ChannelSeen.instance.value,
        builder: (context, seen, child) => _groupTile(context),
      );
    }
    final other = chat.otherUid(me);
    final name = chat.usernameOf(other);
    final fromMe = chat.lastSenderId == me;
    final unread = chat.unreadFor(me);
    // v0.10: Seen / Delivered / Sent for your last message
    var state = 'Sent';
    if (fromMe) {
      final s = chat.seenAt(other);
      final d = chat.deliveredAt(other);
      if (s != null && !s.isBefore(chat.updatedAt)) {
        state = 'Seen';
      } else if (d != null && !d.isBefore(chat.updatedAt)) {
        state = 'Delivered';
      }
    }
    // v0.13: "typing…", and messages that disappeared for you
    final typing = TypingTracker.instance.isTyping(
      chat,
      other,
      serverNow: ServerClock.now(),
    );
    final preview = typing
        ? 'typing…'
        : chat.lastMessage.isEmpty
        ? 'Say hi 👋'
        : fromMe
        ? '$state · You: ${chat.lastMessage}'
        : chat.lastMessage;

    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Avatar(
                    url: chat.photoOf(other),
                    name: name,
                    size: 44,
                    uid: other,
                  ),
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: ActiveDot(uid: other),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: NameBadge(
                            name,
                            uid: other,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (muted)
                          const Padding(
                            padding: EdgeInsets.only(left: 5),
                            child: Icon(
                              Icons.notifications_off_outlined,
                              key: ValueKey('chat-muted-icon'),
                              size: 14,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        if (callsMuted)
                          const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.phone_disabled_outlined,
                              key: ValueKey('chat-calls-muted-icon'),
                              size: 14,
                              color: AppColors.textSecondary,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: unread ? FontWeight.w700 : FontWeight.w400,
                        color: typing
                            ? AppColors.lime
                            : fromMe
                            ? AppColors.textSecondary
                            : AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (pinned)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 3),
                      child: Icon(
                        Icons.push_pin,
                        key: ValueKey('chat-pinned-icon'),
                        size: 13,
                        color: AppColors.lime,
                      ),
                    ),
                  Text(
                    timeAgo(chat.updatedAt, approx: true),
                    style: TextStyle(
                      color: unread ? AppColors.lime : AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  if (unread)
                    Container(
                      key: const ValueKey('unread-dot'),
                      margin: const EdgeInsets.only(top: 6),
                      width: 9,
                      height: 9,
                      decoration: const BoxDecoration(
                        color: AppColors.lime,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
