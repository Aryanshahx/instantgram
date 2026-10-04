import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/errors.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../models/chat.dart';
import '../../services/chat_service.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/state_views.dart';
import '../profile/profile_screen.dart';

/// A one-to-one chat. Anyone can message anyone: open a profile and tap Message.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.otherUid, this.user});

  final String otherUid;

  /// Already loaded profile of the other person (saves a lookup).
  final AppUser? user;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _text = TextEditingController();
  final _service = ChatService.instance;
  late final String _me = UserService.instance.myUid;

  AppUser? _user;
  String? _chatId;
  Stream<List<ChatMessage>>? _stream;
  Object? _error;
  bool _sending = false;
  String? _seenMessageId;

  @override
  void initState() {
    super.initState();
    _user = widget.user;
    _text.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      if (_user == null) {
        UserService.instance.getUser(widget.otherUid).then((u) {
          if (mounted && u != null) setState(() => _user = u);
        });
      }
      final id = await _service.open(widget.otherUid);
      if (!mounted) return;
      setState(() {
        _chatId = id;
        _stream = _service.watchMessages(id);
      });
      _service.markSeen(id);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _send() async {
    final body = _text.text.trim();
    if (body.isEmpty || _sending || _chatId == null) return;
    setState(() => _sending = true);
    _text.clear();
    try {
      await _service.send(widget.otherUid, body);
    } catch (e) {
      if (mounted) {
        _text.text = body;
        showToast(context, friendlyError(e));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _openProfile() =>
      openScreen(context, ProfileScreen(uid: widget.otherUid));

  @override
  Widget build(BuildContext context) {
    final u = _user;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _openProfile,
          child: Row(
            children: [
              UserAvatar(
                url: u?.photoUrl ?? '',
                name: u?.username ?? '',
                radius: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  u?.username ?? '...',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ),
      ),
      body: ContentWidth(
        maxWidth: 680,
        child: Column(
          children: [
            Expanded(child: _messages(context)),
            _composer(context),
          ],
        ),
      ),
    );
  }

  Widget _messages(BuildContext context) {
    if (_error != null) return ErrorState(error: _error!, onRetry: _load);
    final stream = _stream;
    if (stream == null) return const CenteredLoader();
    return StreamBuilder<List<ChatMessage>>(
      stream: stream,
      builder: (context, snap) {
        if (snap.hasError) {
          return ErrorState(error: snap.error!, onRetry: _load);
        }
        final msgs = snap.data;
        if (msgs == null) return const CenteredLoader();
        if (msgs.isEmpty) {
          return EmptyState(
            icon: Icons.waving_hand_rounded,
            title: 'Say hi',
            subtitle: 'Send the first message to ${_user?.username ?? 'them'}.',
          );
        }
        // someone else's new message is on screen: mark the chat as read
        final newest = msgs.first;
        if (newest.senderId != _me && newest.id != _seenMessageId) {
          _seenMessageId = newest.id;
          final id = _chatId;
          if (id != null) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _service.markSeen(id),
            );
          }
        }
        return ListView.builder(
          reverse: true,
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          itemCount: msgs.length,
          itemBuilder: (context, i) {
            final m = msgs[i];
            return MessageBubble(
              text: m.text,
              mine: m.senderId == _me,
              time: chatTime(m.createdAt),
              pending: m.pending,
            );
          },
        );
      },
    );
  }

  Widget _composer(BuildContext context) {
    final canSend = _text.text.trim().isNotEmpty && _chatId != null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('chatInput'),
                controller: _text,
                minLines: 1,
                maxLines: 5,
                maxLength: ChatService.maxLength,
                buildCounter:
                    (
                      _, {
                      required currentLength,
                      required isFocused,
                      maxLength,
                    }) => null,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(hintText: 'Message...'),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              key: const ValueKey('sendButton'),
              onTap: canSend ? _send : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: canSend ? AppTheme.volt : context.cardHigh,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.send_rounded,
                  size: 22,
                  color: canSend ? AppTheme.ink : context.muted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
