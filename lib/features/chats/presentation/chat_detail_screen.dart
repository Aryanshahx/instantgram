import 'package:flutter/material.dart';

import '../../../core/services/content_filter.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/net_image.dart';
import '../data/chat_repository.dart';

class ChatDetailScreen extends StatefulWidget {
  const ChatDetailScreen({super.key, required this.other});

  final UserProfile other;

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final _ctrl = TextEditingController();
  final _repo = ChatRepository.instance;
  late final Stream<List<Message>> _messages = _repo.messages(
    _repo.chatIdWith(widget.other.uid),
  );
  bool _sending = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _ctrl.clear();
    try {
      await _repo.send(widget.other, text);
    } catch (e) {
      _ctrl.text = text;
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.other;
    final me = _repo.myUid;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: GestureDetector(
          onTap: () => openProfile(context, o.uid),
          child: Row(
            children: [
              Avatar(url: o.photoUrl, name: o.username, size: 32, uid: o.uid),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  o.username,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<Message>>(
              stream: _messages,
              builder: (context, snap) {
                if (snap.hasError) return ErrorView(error: snap.error);
                if (!snap.hasData) return const LoadingView();
                final msgs = snap.data!;
                if (msgs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Avatar(
                          url: o.photoUrl,
                          name: o.username,
                          size: 84,
                          uid: o.uid,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          o.username,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Say hi 👋',
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) {
                    final m = msgs[i];
                    final mine = m.senderId == me;
                    return Align(
                      alignment: mine
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.75,
                        ),
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: mine ? AppColors.lime : AppColors.surface,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(20),
                            topRight: const Radius.circular(20),
                            bottomLeft: Radius.circular(mine ? 20 : 6),
                            bottomRight: Radius.circular(mine ? 6 : 20),
                          ),
                          border: mine
                              ? null
                              : Border.all(color: AppColors.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (m.isSharedPost)
                              SharedPostCard(message: m, mine: mine)
                            else
                              Text(
                                m.text,
                                style: TextStyle(
                                  fontSize: 14.5,
                                  color: mine
                                      ? Colors.black
                                      : AppColors.textPrimary,
                                ),
                              ),
                            const SizedBox(height: 2),
                            Text(
                              timeAgo(m.createdAt),
                              style: TextStyle(
                                fontSize: 11,
                                color: mine
                                    ? Colors.black54
                                    : AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (ContentFilter.instance.isBlocked(widget.other.uid))
            const SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 10, 20, 16),
                child: Text(
                  "You blocked this account. Unblock them from their profile "
                  'to send messages.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
            )
          else
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 8, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ctrl,
                        minLines: 1,
                        maxLines: 4,
                        maxLength: 2000,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          counterText: '',
                          hintText: 'Message…',
                          hintStyle: const TextStyle(color: AppColors.textHint),
                          filled: true,
                          fillColor: AppColors.surface,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(26),
                            borderSide: const BorderSide(
                              color: AppColors.border,
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(26),
                            borderSide: const BorderSide(
                              color: AppColors.border,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(26),
                            borderSide: const BorderSide(color: AppColors.lime),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Material(
                      color: AppColors.lime,
                      shape: const CircleBorder(),
                      child: IconButton(
                        onPressed: _sending ? null : _send,
                        iconSize: 20,
                        icon: const Icon(
                          Icons.send_rounded,
                          color: Colors.black,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A post / clip someone shared in the chat. Tap = open it.
class SharedPostCard extends StatelessWidget {
  const SharedPostCard({super.key, required this.message, required this.mine});

  final Message message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final fg = mine ? Colors.black : AppColors.textPrimary;
    return GestureDetector(
      key: ValueKey('shared-post-${m.postId}'),
      onTap: () => openPostById(context, m.postId),
      child: SizedBox(
        width: 190,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '@${m.postAuthor}',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13.5,
                color: fg,
              ),
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: m.postType == Post.clip ? 0.75 : 1,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    NetImage(m.postThumb),
                    if (m.postType == Post.clip)
                      const Positioned(
                        right: 8,
                        top: 8,
                        child: Icon(
                          Icons.smart_display,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (m.postCaption.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                m.postCaption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: fg),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
