import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/call.dart';
import '../models/chat.dart';
import 'location_card.dart';
import 'voice_bubble.dart';

/// One chat message. Mine are volt green on the right, theirs are grey on the left.
///
/// Give it a [message] to show photos, GIFs, voice notes, locations and shared posts,
/// replies, "Forwarded", reactions and pins. Without one it shows plain [text].
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    this.text = '',
    required this.mine,
    required this.time,
    this.pending = false,
    this.message,
    this.nameOf,
    this.myUid = '',
    this.onOpen,
    this.onReact,
    this.onReplyTap,
    this.highlight = false,
  });

  final String text;
  final bool mine;
  final String time;
  final bool pending;
  final ChatMessage? message;

  /// The name shown above a quoted message ("You", a username).
  final String Function(String uid)? nameOf;
  final String myUid;

  /// Tap on the photo, GIF, location or shared post.
  final VoidCallback? onOpen;

  /// Tap on a reaction chip.
  final void Function(String emoji)? onReact;

  /// Tap on the quoted message.
  final VoidCallback? onReplyTap;
  final bool highlight;

  static const double _media = 240;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final maxW = MediaQuery.sizeOf(context).width * 0.74;
    final bg = mine ? AppTheme.volt : context.cardHigh;
    final fg = mine ? AppTheme.ink : Theme.of(context).colorScheme.onSurface;
    final deleted = m?.deleted ?? false;
    final type = deleted ? MsgType.text : (m?.type ?? MsgType.text);
    final framed = type == MsgType.image || type == MsgType.gif;
    final rx = m?.reactionCounts ?? const <String, int>{};

    final children = <Widget>[];
    if (m != null && !deleted) {
      if (m.pinned) {
        children.add(_tag(Icons.push_pin_rounded, 'Pinned', fg));
      }
      if (m.forwarded) {
        children.add(_tag(Icons.shortcut_rounded, 'Forwarded', fg));
      }
      final r = m.replyTo;
      if (r != null) children.add(_quote(context, r, fg));
    }
    children.add(_content(context, m, type, deleted, fg));
    if (m != null && !deleted && m.type == MsgType.post && m.text.isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            m.text,
            style: TextStyle(color: fg, fontSize: 15, height: 1.3),
          ),
        ),
      );
    }
    children.add(const SizedBox(height: 3));
    children.add(
      Text(
        pending ? 'Sending...' : time,
        style: TextStyle(
          color: fg.withValues(alpha: 0.55),
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    final bubble = AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      margin: EdgeInsets.only(top: 3, bottom: rx.isEmpty ? 3 : 14),
      padding: framed && (m?.replyTo == null) && !(m?.forwarded ?? false)
          ? const EdgeInsets.fromLTRB(4, 4, 4, 6)
          : const EdgeInsets.fromLTRB(12, 9, 12, 7),
      decoration: BoxDecoration(
        color: bg,
        border: highlight ? Border.all(color: AppTheme.violet, width: 2) : null,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(20),
          topRight: const Radius.circular(20),
          bottomLeft: Radius.circular(mine ? 20 : 5),
          bottomRight: Radius.circular(mine ? 5 : 20),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW > 420 ? 420 : maxW),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            bubble,
            if (rx.isNotEmpty)
              Positioned(
                bottom: 0,
                right: mine ? 10 : null,
                left: mine ? null : 10,
                child: _reactions(context, rx, m?.reactions[myUid]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tag(IconData icon, String label, Color fg) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: fg.withValues(alpha: 0.6)),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: fg.withValues(alpha: 0.6),
              fontSize: 11.5,
              fontStyle: FontStyle.italic,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _quote(BuildContext context, ReplyRef r, Color fg) {
    final name = nameOf?.call(r.senderId) ?? '';
    return GestureDetector(
      key: const ValueKey('replyQuote'),
      onTap: onReplyTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(9, 6, 9, 6),
        decoration: BoxDecoration(
          color: fg.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(10),
          border: Border(
            left: BorderSide(
              color: mine ? AppTheme.ink : AppTheme.violet,
              width: 3,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (name.isNotEmpty)
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            Text(
              messagePreview(r.kind, r.preview),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: fg.withValues(alpha: 0.8), fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    ChatMessage? m,
    String type,
    bool deleted,
    Color fg,
  ) {
    if (deleted) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.block_rounded,
              size: 15,
              color: fg.withValues(alpha: 0.55),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'This message was deleted',
                style: TextStyle(
                  color: fg.withValues(alpha: 0.6),
                  fontSize: 14.5,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (m == null || type == MsgType.text) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          m?.text ?? text,
          style: TextStyle(color: fg, fontSize: 15.5, height: 1.3),
        ),
      );
    }
    switch (type) {
      case MsgType.image:
      case MsgType.gif:
        final w = _media;
        final a = m.aspect.clamp(0.6, 1.8);
        final h = (w / a).clamp(110.0, 330.0);
        return GestureDetector(
          key: ValueKey(type == MsgType.gif ? 'gifMessage' : 'imageMessage'),
          onTap: onOpen,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: w,
              height: h,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImage(
                    imageUrl: m.mediaUrl,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => ColoredBox(color: context.softFill),
                    errorWidget: (_, _, _) => ColoredBox(
                      color: context.softFill,
                      child: const Icon(Icons.broken_image_rounded),
                    ),
                  ),
                  if (type == MsgType.gif)
                    Positioned(
                      left: 8,
                      top: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'GIF',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      case MsgType.voice:
        return VoiceBubble(url: m.mediaUrl, seconds: m.duration, color: fg);
      case MsgType.location:
        return LocationCard(
          lat: m.lat,
          lng: m.lng,
          onTap: onOpen,
          textColor: fg,
        );
      case MsgType.post:
        return _PostShareCard(message: m, fg: fg, onTap: onOpen);
      case MsgType.call:
        return _callLine(m, fg);
    }
    return const SizedBox.shrink();
  }

  /// "Voice call 2:31" / "Missed video call"; tap to call again.
  Widget _callLine(ChatMessage m, Color fg) {
    final missed =
        m.callStatus == CallStatus.missed ||
        m.callStatus == CallStatus.declined;
    final label = callLabel(video: m.callVideo, status: m.callStatus);
    return InkWell(
      key: const ValueKey('callMessage'),
      onTap: onOpen,
      borderRadius: BorderRadius.circular(12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: fg.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              m.callVideo
                  ? (missed
                        ? Icons.videocam_off_rounded
                        : Icons.videocam_rounded)
                  : (missed ? Icons.phone_missed_rounded : Icons.call_rounded),
              size: 20,
              color: missed ? AppTheme.coral : fg,
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  m.duration > 0
                      ? formatCallTime(m.duration)
                      : 'Tap to call back',
                  style: TextStyle(
                    color: fg.withValues(alpha: 0.65),
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _reactions(BuildContext context, Map<String, int> rx, String? mine) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: context.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final e in rx.entries)
            GestureDetector(
              key: ValueKey('reaction_${e.key}'),
              behavior: HitTestBehavior.opaque,
              onTap: onReact == null ? null : () => onReact!(e.key),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  e.value > 1 ? '${e.key} ${e.value}' : e.key,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: e.key == mine
                        ? FontWeight.w800
                        : FontWeight.w500,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A post or clip someone sent: thumbnail, who made it and its title.
class _PostShareCard extends StatelessWidget {
  const _PostShareCard({required this.message, required this.fg, this.onTap});

  final ChatMessage message;
  final Color fg;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final m = message;
    return GestureDetector(
      key: const ValueKey('postShareCard'),
      onTap: onTap,
      child: SizedBox(
        width: 220,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: ColoredBox(
            color: fg.withValues(alpha: 0.08),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: m.postIsClip ? 260 : 190,
                  width: double.infinity,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      m.postThumbUrl.isEmpty
                          ? ColoredBox(
                              color: context.softFill,
                              child: Icon(
                                m.postIsClip
                                    ? Icons.movie_rounded
                                    : Icons.image_rounded,
                                size: 40,
                              ),
                            )
                          : CachedNetworkImage(
                              imageUrl: m.postThumbUrl,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) =>
                                  ColoredBox(color: context.softFill),
                            ),
                      if (m.postIsClip)
                        const Center(
                          child: Icon(
                            Icons.play_circle_fill_rounded,
                            size: 46,
                            color: Colors.white70,
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        m.postAuthor.isEmpty ? '' : '@${m.postAuthor}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fg,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (m.postTitle.isNotEmpty)
                        Text(
                          m.postTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: fg.withValues(alpha: 0.85),
                            fontSize: 13,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "14:05" for today, "Mon 14:05" within a week, otherwise "12 Sep".
String chatTime(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final local = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(local.hour)}:${two(local.minute)}';
  final sameDay =
      local.year == n.year && local.month == n.month && local.day == n.day;
  if (sameDay) return hm;
  final days = DateTime(
    n.year,
    n.month,
    n.day,
  ).difference(DateTime(local.year, local.month, local.day)).inDays;
  const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const mo = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  if (days >= 0 && days < 7) return '${wd[local.weekday - 1]} $hm';
  return '${local.day} ${mo[local.month - 1]}';
}
