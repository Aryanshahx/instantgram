import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/net_image.dart';
import '../data/chat_repository.dart';

/// Quick reactions on a long-press (v0.9).
const List<String> kReactEmojis = ['❤️', '😂', '😮', '😢', '😡', '👍'];

enum MessageAction { reply, forward, copy, pin, unpin, deleteAll, deleteMe }

/// What was chosen in the long-press menu: an action or an emoji
/// (emoji '' = remove my reaction).
class MessageMenuResult {
  const MessageMenuResult.action(MessageAction this.action) : emoji = null;
  const MessageMenuResult.react(String this.emoji) : action = null;
  final MessageAction? action;
  final String? emoji;
}

/// "0:07", "1:25"
String formatDuration(int ms) {
  final s = (ms / 1000).round().clamp(0, 359999);
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Long-press menu: emoji row + Reply / Forward / Copy / Pin / Delete.
Future<MessageMenuResult?> showMessageMenu(
  BuildContext context, {
  required Message message,
  required bool mine,
  required bool pinned,
  String? myEmoji,
}) {
  HapticFeedback.mediumImpact();
  return showModalBottomSheet<MessageMenuResult>(
    context: context,
    backgroundColor: AppColors.surface,
    builder: (ctx) {
      Widget item(
        MessageAction a,
        IconData icon,
        String label, {
        bool danger = false,
      }) {
        final color = danger ? AppColors.like : AppColors.textPrimary;
        return ListTile(
          key: ValueKey('msg-${a.name}'),
          dense: true,
          leading: Icon(icon, color: color, size: 22),
          title: Text(
            label,
            style: TextStyle(
              color: color,
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
          onTap: () => Navigator.pop(ctx, MessageMenuResult.action(a)),
        );
      }

      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final e in kReactEmojis)
                      GestureDetector(
                        key: ValueKey('react-$e'),
                        onTap: () => Navigator.pop(
                          ctx,
                          MessageMenuResult.react(e == myEmoji ? '' : e),
                        ),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: e == myEmoji
                                ? AppColors.surfaceHigh
                                : Colors.transparent,
                          ),
                          child: Text(e, style: const TextStyle(fontSize: 28)),
                        ),
                      ),
                  ],
                ),
              ),
              item(MessageAction.reply, Icons.reply_rounded, 'Reply'),
              if (!message.isCall)
                item(MessageAction.forward, Icons.shortcut_rounded, 'Forward'),
              if (message.text.isNotEmpty || message.isLocation)
                item(MessageAction.copy, Icons.copy_rounded, 'Copy'),
              if (pinned)
                item(MessageAction.unpin, Icons.push_pin_outlined, 'Unpin')
              else
                item(MessageAction.pin, Icons.push_pin_outlined, 'Pin'),
              if (mine)
                item(
                  MessageAction.deleteAll,
                  Icons.delete_forever_outlined,
                  'Delete for everyone',
                  danger: true,
                ),
              item(
                MessageAction.deleteMe,
                Icons.delete_outline,
                'Delete for you',
                danger: true,
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Swipe a message to the right to answer it (with a small vibration).
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({super.key, required this.child, required this.onReply});
  final Widget child;
  final VoidCallback onReply;

  static const double trigger = 64;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  double _dx = 0;
  bool _armed = false;
  // made in initState (not lazily): creating it while the message is
  // being removed from the screen is an error (v0.9.1 fix)
  late final AnimationController _back;
  double _from = 0;

  @override
  void initState() {
    super.initState();
    _back = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    )..addListener(() {
        if (mounted) setState(() => _dx = _from * (1 - _back.value));
      });
  }

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    _back.stop();
    setState(() => _dx = (_dx + d.delta.dx).clamp(0.0, 90.0));
    final armed = _dx >= SwipeToReply.trigger;
    if (armed && !_armed) HapticFeedback.lightImpact();
    _armed = armed;
  }

  void _end([DragEndDetails? _]) {
    if (_armed) widget.onReply();
    _armed = false;
    if (_dx <= 0) return; // a tap, not a swipe: nothing to slide back
    _from = _dx;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final p = (_dx / SwipeToReply.trigger).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: _end,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          if (_dx > 4)
            Positioned(
              left: 4,
              child: Opacity(
                opacity: p,
                child: Transform.scale(
                  scale: 0.6 + 0.4 * p,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(
                      color: AppColors.surfaceHigh,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.reply_rounded, size: 18),
                  ),
                ),
              ),
            ),
          Transform.translate(offset: Offset(_dx, 0), child: widget.child),
        ],
      ),
    );
  }
}

/// The message being answered, shown inside a bubble / above the input.
class QuoteBox extends StatelessWidget {
  const QuoteBox({
    super.key,
    required this.title,
    required this.text,
    this.onDark = true,
  });
  final String title;
  final String text;

  /// false = on the lime bubble (dark text).
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final fg = onDark ? AppColors.textPrimary : Colors.black;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(9, 5, 9, 6),
      decoration: BoxDecoration(
        color: onDark ? AppColors.surfaceHigh : Colors.black12,
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(
            color: onDark ? AppColors.lime : Colors.black54,
            width: 3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
          Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: fg.withValues(alpha: 0.8)),
          ),
        ],
      ),
    );
  }
}

/// One chat message (text, post, photo, GIF, voice, location) with its
/// reply quote, "Forwarded" label, time and reactions.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.mine,
    required this.myUid,
    required this.otherName,
    this.onLongPress,
    this.onReactionsTap,
    this.onQuoteTap,
    this.tick = MessageTick.none,
    this.onCallTap,
  });

  final Message message;
  final bool mine;

  /// v0.11: tap a call log = call back.
  final VoidCallback? onCallTap;
  final String myUid;
  final String otherName;
  final VoidCallback? onLongPress;
  final VoidCallback? onReactionsTap;

  /// v0.10: tap the reply quote = jump to that message.
  final VoidCallback? onQuoteTap;

  /// v0.10: ✓ / ✓✓ / green ✓✓ / clock on your own messages.
  final MessageTick tick;

  bool get _bare => message.isImage || message.isGif;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final maxW = MediaQuery.of(context).size.width * 0.75;
    final fg = mine ? Colors.black : AppColors.textPrimary;
    final sub = mine ? Colors.black54 : AppColors.textSecondary;
    final q = m.replyTo;
    final header = <Widget>[
      if (m.forwarded)
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.shortcut_rounded, size: 13, color: sub),
              const SizedBox(width: 3),
              Text(
                'Forwarded',
                style: TextStyle(
                  fontSize: 11.5,
                  fontStyle: FontStyle.italic,
                  color: sub,
                ),
              ),
            ],
          ),
        ),
      if (q != null)
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onQuoteTap,
          child: QuoteBox(
            key: ValueKey('quote-${m.id}'),
            title: q.senderId == myUid ? 'You' : otherName,
            text: q.text,
            onDark: !mine || _bare,
          ),
        ),
    ];
    final timeText = Text(
      timeAgo(m.createdAt),
      style: TextStyle(
        fontSize: 11,
        color: _bare ? AppColors.textSecondary : sub,
      ),
    );
    final time = tick == MessageTick.none && !m.disappears
        ? timeText
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // v0.11: this message disappears
              if (m.disappears)
                Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: Icon(
                    m.vanish ? Icons.visibility_off_outlined : Icons.timer_outlined,
                    key: ValueKey('vanish-${m.id}'),
                    size: 11,
                    color: _bare ? AppColors.textSecondary : sub,
                  ),
                ),
              timeText,
              if (tick != MessageTick.none) ...[
                const SizedBox(width: 3),
                TickIcon(tick: tick, onDark: _bare),
              ],
            ],
          );

    Widget content;
    if (m.isSharedPost) {
      content = SharedPostCard(message: m, mine: mine);
    } else if (_bare) {
      content = _MediaPicture(message: m, maxWidth: maxW * 0.85);
    } else if (m.isVoice) {
      content = VoiceBubble(
        key: ValueKey('voice-${m.id}'),
        url: m.mediaUrl,
        durationMs: m.durationMs,
        mine: mine,
      );
    } else if (m.isLocation) {
      content = LocationCard(message: m, mine: mine);
    } else if (m.isCall) {
      content = CallLogContent(message: m, mine: mine, onTap: onCallTap);
    } else {
      content = Text(m.text, style: TextStyle(fontSize: 14.5, color: fg));
    }

    final bubble = _bare
        ? Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [...header, content, const SizedBox(height: 3), time],
          )
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: mine ? AppColors.lime : AppColors.surface,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(20),
                topRight: const Radius.circular(20),
                bottomLeft: Radius.circular(mine ? 20 : 6),
                bottomRight: Radius.circular(mine ? 6 : 20),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (header.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: header,
                    ),
                  ),
                content,
                const SizedBox(height: 2),
                time,
              ],
            ),
          );

    final counts = m.reactionCounts;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        key: ValueKey('msg-${m.id}'),
        onLongPress: onLongPress,
        child: Padding(
          padding: EdgeInsets.only(top: 3, bottom: counts.isEmpty ? 3 : 14),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                bubble,
                if (counts.isNotEmpty)
                  Positioned(
                    bottom: -13,
                    right: mine ? 10 : null,
                    left: mine ? null : 10,
                    child: GestureDetector(
                      key: ValueKey('reactions-${m.id}'),
                      onTap: onReactionsTap,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceHigh,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppColors.background,
                            width: 2,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final e in counts.take(3))
                              Text(e.key, style: const TextStyle(fontSize: 13)),
                            if (m.reactions.length > 1) ...[
                              const SizedBox(width: 3),
                              Text(
                                '${m.reactions.length}',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
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

/// v0.11: "Voice call · 2:31" / "Missed video call". Tap = call back.
class CallLogContent extends StatelessWidget {
  const CallLogContent({
    super.key,
    required this.message,
    required this.mine,
    this.onTap,
  });
  final Message message;
  final bool mine;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final missed = m.callStatus == 'missed' || m.callStatus == 'busy';
    final fg = mine ? Colors.black : AppColors.textPrimary;
    final sub = mine ? Colors.black54 : AppColors.textSecondary;
    final what = m.video ? 'Video call' : 'Voice call';
    final title = mine && missed ? '$what · No answer' : m.callLabel;
    final IconData icon;
    if (missed && !mine) {
      icon = Icons.call_missed_rounded;
    } else if (m.video) {
      icon = Icons.videocam_rounded;
    } else {
      icon = mine ? Icons.call_made_rounded : Icons.call_received_rounded;
    }
    return GestureDetector(
      key: ValueKey('call-log-${m.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: mine ? Colors.black12 : AppColors.surfaceHigh,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              size: 19,
              color: missed && !mine ? AppColors.like : fg,
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: missed && !mine ? AppColors.like : fg,
                  ),
                ),
                Text(
                  'Tap to call back',
                  style: TextStyle(fontSize: 12, color: sub),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// v0.11: "alice turned on disappearing messages" (middle of the chat).
class SystemNote extends StatelessWidget {
  const SystemNote({super.key, required this.text, this.onTap});
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
      child: Center(
        child: GestureDetector(
          onTap: onTap,
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12.5,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// Photo / GIF in a chat. Tap a photo = full screen.
class _MediaPicture extends StatelessWidget {
  const _MediaPicture({required this.message, required this.maxWidth});
  final Message message;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final w = maxWidth.clamp(120.0, 280.0);
    return GestureDetector(
      key: ValueKey('picture-${m.id}'),
      onTap: m.isImage ? () => openPhotoViewer(context, m.mediaUrl) : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: w,
          child: AspectRatio(
            aspectRatio: m.aspect,
            child: ColoredBox(
              color: AppColors.surface,
              child: NetImage(m.mediaUrl),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full screen photo with pinch zoom.
Future<void> openPhotoViewer(BuildContext context, String url) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (ctx) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black),
        body: Center(
          child: InteractiveViewer(
            maxScale: 5,
            child: NetImage(url, fit: BoxFit.contain),
          ),
        ),
      ),
    ),
  );
}

/// Voice message: play / pause, progress and length.
/// Only one voice message plays at a time.
class VoiceBubble extends StatefulWidget {
  const VoiceBubble({
    super.key,
    required this.url,
    required this.durationMs,
    required this.mine,
  });
  final String url;
  final int durationMs;
  final bool mine;

  /// Tests: never touch the audio plugin.
  static bool disabled = false;
  static _VoiceBubbleState? _playing;

  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble> {
  AudioPlayer? _p;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _posSub;
  bool _playing = false;
  bool _loading = false;
  Duration _pos = Duration.zero;

  @override
  void dispose() {
    if (VoiceBubble._playing == this) VoiceBubble._playing = null;
    _stateSub?.cancel();
    _posSub?.cancel();
    _p?.dispose();
    super.dispose();
  }

  void _stop() {
    _p?.pause();
    if (mounted) setState(() => _playing = false);
  }

  Future<void> _toggle() async {
    if (VoiceBubble.disabled) {
      setState(() => _playing = !_playing);
      return;
    }
    if (_playing) {
      _stop();
      return;
    }
    final other = VoiceBubble._playing;
    if (other != null && other != this) other._stop();
    VoiceBubble._playing = this;
    var p = _p;
    if (p == null) {
      p = _p = AudioPlayer(handleInterruptions: false);
      _stateSub = p.playerStateStream.listen((s) {
        if (!mounted) return;
        if (s.processingState == ProcessingState.completed) {
          p!.pause();
          p.seek(Duration.zero);
          setState(() {
            _playing = false;
            _pos = Duration.zero;
          });
        }
      });
      _posSub = p.positionStream.listen((d) {
        if (mounted) setState(() => _pos = d);
      });
      setState(() => _loading = true);
      try {
        await p.setUrl(widget.url);
      } catch (e) {
        if (mounted) {
          setState(() => _loading = false);
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text("Couldn't play: ${friendlyError(e)}")),
          );
        }
        return;
      }
      if (!mounted) return;
      setState(() => _loading = false);
    }
    setState(() => _playing = true);
    p.play(); // don't await (ends when playback stops)
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.mine ? Colors.black : AppColors.textPrimary;
    final total = widget.durationMs > 0
        ? widget.durationMs
        : (_p?.duration?.inMilliseconds ?? 0);
    final progress = total > 0
        ? (_pos.inMilliseconds / total).clamp(0.0, 1.0)
        : 0.0;
    return SizedBox(
      width: 190,
      child: Row(
        children: [
          InkResponse(
            key: const ValueKey('voice-play'),
            onTap: _loading ? null : _toggle,
            child: SizedBox(
              width: 34,
              height: 34,
              child: _loading
                  ? Padding(
                      padding: const EdgeInsets.all(8),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: fg,
                      ),
                    )
                  : Icon(
                      _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: fg,
                      size: 30,
                    ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                color: fg,
                backgroundColor: fg.withValues(alpha: 0.25),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            formatDuration(
              _playing || _pos > Duration.zero ? _pos.inMilliseconds : total,
            ),
            style: TextStyle(
              fontSize: 12,
              color: fg,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Location card: little map with a pin + the address.
/// Tap = Google Maps (free, no API key).
class LocationCard extends StatelessWidget {
  const LocationCard({super.key, required this.message, required this.mine});
  final Message message;
  final bool mine;

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await launchUrl(
      message.mapsUri,
      mode: LaunchMode.externalApplication,
    ).catchError((Object _) => false);
    if (!ok) {
      messenger?.showSnackBar(
        const SnackBar(content: Text("Couldn't open Google Maps")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = message;
    final fg = mine ? Colors.black : AppColors.textPrimary;
    return GestureDetector(
      key: ValueKey('location-${m.id}'),
      onTap: () => _open(context),
      child: SizedBox(
        width: 210,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 110,
                width: double.infinity,
                child: CustomPaint(
                  painter: _MapPainter(),
                  child: const Center(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: 18),
                      child: Icon(
                        Icons.location_on,
                        size: 40,
                        color: Color(0xFFFF4D5E),
                        shadows: [Shadow(blurRadius: 6, color: Colors.black45)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              m.address.isNotEmpty ? m.address : 'Shared location',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
                color: fg,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Icon(
                  Icons.map_outlined,
                  size: 14,
                  color: fg.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    'Open in Google Maps',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: fg.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Simple drawn "map" (streets + park), no map service needed.
class _MapPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF1E2430);
    canvas.drawRect(Offset.zero & size, bg);
    final park = Paint()..color = const Color(0xFF243A2B);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          size.width * 0.62,
          size.height * 0.08,
          size.width * 0.3,
          size.height * 0.36,
        ),
        const Radius.circular(8),
      ),
      park,
    );
    final water = Paint()..color = const Color(0xFF1C3347);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-10, size.height * 0.7, size.width * 0.4, size.height),
        const Radius.circular(20),
      ),
      water,
    );
    final road = Paint()
      ..color = const Color(0xFF39404E)
      ..strokeWidth = 7;
    final small = Paint()
      ..color = const Color(0xFF2C3340)
      ..strokeWidth = 3;
    canvas.drawLine(
      Offset(0, size.height * 0.55),
      Offset(size.width, size.height * 0.45),
      road,
    );
    canvas.drawLine(
      Offset(size.width * 0.45, 0),
      Offset(size.width * 0.52, size.height),
      road,
    );
    for (var i = 1; i < 6; i++) {
      final x = size.width * i / 6;
      canvas.drawLine(Offset(x, 0), Offset(x + 12, size.height), small);
    }
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y - 6), small);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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

/// Loads people to forward to (tests replace this).
typedef ForwardTargetsLoader = Future<List<ChatPerson>> Function();
typedef ForwardSender = Future<void> Function(ChatPerson to);

/// Pick people to forward a message to.
Future<void> showForwardSheet(
  BuildContext context, {
  required ForwardSender send,
  ForwardTargetsLoader? loadTargets,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    builder: (_) => ForwardSheet(
      send: send,
      loadTargets: loadTargets ?? ChatRepository.instance.shareTargets,
    ),
  );
}

class ForwardSheet extends StatefulWidget {
  const ForwardSheet({
    super.key,
    required this.send,
    required this.loadTargets,
  });
  final ForwardSender send;
  final ForwardTargetsLoader loadTargets;

  @override
  State<ForwardSheet> createState() => _ForwardSheetState();
}

class _ForwardSheetState extends State<ForwardSheet> {
  late final Future<List<ChatPerson>> _targets = widget.loadTargets();
  final _search = TextEditingController();
  String _q = '';
  final Set<String> _sent = {};
  final Set<String> _sending = {};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _send(ChatPerson p) async {
    if (_sent.contains(p.uid) || _sending.contains(p.uid)) return;
    setState(() => _sending.add(p.uid));
    try {
      await widget.send(p);
      if (mounted) setState(() => _sent.add(p.uid));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _sending.remove(p.uid));
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: h * 0.6,
        child: Column(
          children: [
            const Text(
              'Forward to',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: TextField(
                key: const ValueKey('forward-search'),
                controller: _search,
                onChanged: (v) => setState(() => _q = v),
                decoration: InputDecoration(
                  hintText: 'Search',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  filled: true,
                  fillColor: AppColors.background,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<ChatPerson>>(
                future: _targets,
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final list = snap.data!.where((p) => p.matches(_q)).toList();
                  if (list.isEmpty) {
                    return const Center(
                      child: Text(
                        'Nobody found',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final p = list[i];
                      final sent = _sent.contains(p.uid);
                      final busy = _sending.contains(p.uid);
                      return ListTile(
                        leading: Avatar(
                          url: p.photoUrl,
                          name: p.username,
                          size: 40,
                          uid: p.uid,
                        ),
                        title: Text(
                          p.username,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        trailing: SizedBox(
                          width: 84,
                          height: 34,
                          child: FilledButton(
                            key: ValueKey('forward-${p.uid}'),
                            style: FilledButton.styleFrom(
                              padding: EdgeInsets.zero,
                              backgroundColor: sent
                                  ? AppColors.surfaceHigh
                                  : AppColors.lime,
                              foregroundColor: sent
                                  ? AppColors.textPrimary
                                  : Colors.black,
                              textStyle: TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            onPressed: sent || busy ? null : () => _send(p),
                            child: busy
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(sent ? 'Sent' : 'Send'),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// v0.10 message ticks (your own messages).
enum MessageTick { none, pending, sent, delivered, seen }

/// Clock / ✓ / ✓✓ / blue ✓✓.
class TickIcon extends StatelessWidget {
  const TickIcon({super.key, required this.tick, this.onDark = false});
  final MessageTick tick;

  /// true = on the dark background (photos, GIFs), false = lime bubble.
  final bool onDark;

  /// Colour of seen ticks (v0.12: blue).
  static Color seenColor({required bool onDark}) =>
      onDark ? const Color(0xFF34B7F1) : const Color(0xFF0B5FD0);

  @override
  Widget build(BuildContext context) {
    final grey = onDark ? AppColors.textSecondary : Colors.black54;
    // v0.12: blue (like WhatsApp), darker on the lime bubble so it shows
    final blue = seenColor(onDark: onDark);
    final (IconData icon, Color color, String key) = switch (tick) {
      MessageTick.pending => (Icons.schedule_rounded, grey, 'tick-pending'),
      MessageTick.sent => (Icons.done_rounded, grey, 'tick-sent'),
      MessageTick.delivered => (Icons.done_all_rounded, grey, 'tick-delivered'),
      MessageTick.seen => (Icons.done_all_rounded, blue, 'tick-seen'),
      MessageTick.none => (Icons.done_rounded, grey, 'tick-none'),
    };
    return Icon(
      icon,
      key: ValueKey(key),
      size: tick == MessageTick.pending ? 12 : 15,
      color: color,
    );
  }
}
