import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../../core/services/calls.dart';
import '../../../core/services/content_filter.dart';
import '../../../core/services/location_service.dart';
import '../../../core/services/media_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../shared/models/post.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/active_status.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/attach_menu.dart';
import '../../../shared/widgets/avatar.dart';
import '../../post/presentation/gif_picker.dart';
import '../data/chat_repository.dart';
import 'message_widgets.dart';

export 'message_widgets.dart' show SharedPostCard;

/// One chat (v0.9): text, photos, GIFs, voice, location, reactions,
/// reply (long-press or swipe right), forward, pin, delete, calls.
class ChatDetailScreen extends StatefulWidget {
  const ChatDetailScreen({
    super.key,
    required this.other,
    this.messages,
    this.chat,
    this.myUid,
    this.presence,
  });

  final UserProfile other;

  /// Tests: "Active" status of [other].
  final Stream<DateTime?>? presence;

  /// Tests: replace Firestore.
  final Stream<List<Message>>? messages;
  final Stream<Chat?>? chat;
  final String? myUid;

  /// Longest voice message.
  static const Duration maxVoice = Duration(minutes: 5);

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  final _repo = ChatRepository.instance;
  late final String _me = widget.myUid ?? _repo.myUid;
  late final String _chatId = _chatIdFor(_me, widget.other.uid);
  late final Stream<List<Message>> _messages =
      widget.messages ?? _repo.messages(_chatId);
  late final Stream<Chat?> _chat = widget.chat ?? _repo.chat(_chatId);
  late final ChatPerson _other = ChatPerson.of(widget.other);
  final Map<String, GlobalKey> _keys = {};
  final _scroll = ScrollController();

  /// Tests pass streams: then nothing is written to Firestore.
  bool get _live => widget.messages == null;
  StreamSubscription<Chat?>? _chatSub;
  AppLifecycleListener? _life;
  List<Message> _shown = const [];
  String? _seenAskedFor; // newest message we sent "seen" for
  String? _flashId; // message highlighted after a jump
  Timer? _flashTimer;

  bool _sending = false;
  String? _busyText; // "Sending photo…"
  Message? _replyTo;
  Chat? _chatNow;

  // voice recording
  AudioRecorder? _rec;
  bool _recording = false;
  DateTime? _recStart;
  Timer? _recTimer;
  Duration _recFor = Duration.zero;

  static String _chatIdFor(String a, String b) {
    final ids = [a, b]..sort();
    return ids.join('_');
  }

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onText);
    _chatSub = _chat.listen((c) {
      if (!mounted) return;
      setState(() => _chatNow = c);
      _checkSeen();
    }, onError: (Object e) => debugPrint('chat: $e'));
    _life = AppLifecycleListener(onResume: _checkSeen);
  }

  // ------------------------------------------------------- v0.10 ticks

  /// While you look at the chat: tell the other person "seen".
  void _checkSeen() {
    if (!_live || !mounted) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    Message? newest;
    for (final m in _shown) {
      if (m.senderId != _me) {
        newest = m;
        break;
      }
    }
    if (newest == null || newest.id == _seenAskedFor) return;
    final seen = _chatNow?.seenAt(_me);
    if (seen != null && !seen.isBefore(newest.createdAt)) return;
    _seenAskedFor = newest.id;
    _repo.markSeen(_chatId).catchError((Object e) {
      _seenAskedFor = null;
      debugPrint('seen: $e');
    });
  }

  /// ✓ sent, ✓✓ delivered, green ✓✓ seen, clock = still sending.
  MessageTick _tickFor(Message m) {
    if (m.senderId != _me) return MessageTick.none;
    if (m.pending) return MessageTick.pending;
    final other = widget.other.uid;
    final seen = _chatNow?.seenAt(other);
    if (seen != null && !seen.isBefore(m.createdAt)) return MessageTick.seen;
    final got = _chatNow?.deliveredAt(other);
    if (got != null && !got.isBefore(m.createdAt)) {
      return MessageTick.delivered;
    }
    return MessageTick.sent;
  }

  bool _hadText = false;
  void _onText() {
    final has = _ctrl.text.trim().isNotEmpty;
    if (has != _hadText) setState(() => _hadText = has);
  }

  @override
  void dispose() {
    _chatSub?.cancel();
    _life?.dispose();
    _flashTimer?.cancel();
    _scroll.dispose();
    _recTimer?.cancel();
    if (_recording) _rec?.cancel();
    _rec?.dispose();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  MessageQuote? get _quote {
    final m = _replyTo;
    if (m == null) return null;
    final t = m.isSharedPost ? 'Post by @${m.postAuthor}' : m.preview;
    return MessageQuote(
      id: m.id,
      senderId: m.senderId,
      text: t.length > 300 ? t.substring(0, 300) : t,
    );
  }

  void _reply(Message m) {
    HapticFeedback.selectionClick();
    setState(() => _replyTo = m);
    _focus.requestFocus();
  }

  /// Runs a send; shows [label] while busy and clears the reply.
  Future<void> _run(String? label, Future<void> Function() job) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _busyText = label;
    });
    try {
      await job();
      if (mounted) setState(() => _replyTo = null);
    } catch (e) {
      _snack(friendlyError(e));
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _busyText = null;
        });
      }
    }
  }

  Future<void> _sendText() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    final quote = _quote;
    _ctrl.clear();
    await _run(null, () async {
      try {
        await _repo.send(widget.other, text, replyTo: quote);
      } catch (_) {
        _ctrl.text = text;
        rethrow;
      }
    });
  }

  // ------------------------------------------------------------- attach

  Future<void> _attach() async {
    final what = await showAttachMenu(context, const [
      AttachOption('photo', Icons.photo_outlined, 'Photo', AppColors.lime),
      AttachOption('gif', Icons.gif_box_outlined, 'GIF', AppColors.mint),
      AttachOption(
        'location',
        Icons.location_on_outlined,
        'Location',
        Color(0xFFFFB86B),
      ),
    ]);
    if (!mounted || what == null) return;
    switch (what) {
      case 'photo':
        await _sendPhoto();
      case 'gif':
        await _sendGif();
      case 'location':
        await _sendLocation();
    }
  }

  Future<void> _sendPhoto() async {
    final f = await MediaService.instance.pickGalleryImage();
    if (f == null || !mounted) return;
    final quote = _quote;
    await _run(
      'Sending photo…',
      () => _repo.sendImage(_other, f, replyTo: quote),
    );
  }

  Future<void> _sendGif() async {
    final g = await showGifPicker(context);
    if (g == null || !mounted) return;
    final quote = _quote;
    await _run(null, () => _repo.sendGif(_other, g.gif, replyTo: quote));
  }

  Future<void> _sendLocation() async {
    setState(() => _busyText = 'Finding your location…');
    PickedLocation loc;
    try {
      loc = await LocationService.instance.current();
    } on LocationProblem catch (e) {
      if (mounted) setState(() => _busyText = null);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          action: e.openSettings
              ? SnackBarAction(
                  label: 'Settings',
                  onPressed: LocationService.instance.openSettings,
                )
              : null,
        ),
      );
      return;
    } catch (e) {
      if (mounted) setState(() => _busyText = null);
      _snack(friendlyError(e));
      return;
    }
    if (!mounted) return;
    setState(() => _busyText = null);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send your location?'),
        content: Text(
          loc.address.isNotEmpty
              ? loc.address
              : '${loc.lat.toStringAsFixed(5)}, ${loc.lng.toStringAsFixed(5)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('location-send'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final quote = _quote;
    await _run(
      null,
      () => _repo.sendLocation(
        _other,
        lat: loc.lat,
        lng: loc.lng,
        address: loc.address,
        replyTo: quote,
      ),
    );
  }

  // -------------------------------------------------------------- voice

  Future<void> _startRecording() async {
    if (_sending || _recording) return;
    final r = _rec ??= AudioRecorder();
    try {
      if (!await r.hasPermission()) {
        _snack('Allow the microphone to send voice messages.');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await r.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );
    } catch (e) {
      _snack("Couldn't record: ${friendlyError(e)}");
      return;
    }
    HapticFeedback.mediumImpact();
    _recStart = DateTime.now();
    _recTimer?.cancel();
    _recTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      final d = DateTime.now().difference(_recStart!);
      setState(() => _recFor = d);
      if (d >= ChatDetailScreen.maxVoice) _stopRecording(send: true);
    });
    setState(() {
      _recording = true;
      _recFor = Duration.zero;
    });
  }

  Future<void> _stopRecording({required bool send}) async {
    if (!_recording) return;
    _recTimer?.cancel();
    final ms = DateTime.now().difference(_recStart!).inMilliseconds;
    setState(() => _recording = false);
    final r = _rec;
    if (r == null) return;
    if (!send) {
      await r.cancel();
      return;
    }
    String? path;
    try {
      path = await r.stop();
    } catch (_) {}
    if (path == null || ms < 800) {
      _snack('Too short. Tap the mic, talk, then tap send.');
      return;
    }
    final file = File(path);
    final quote = _quote;
    await _run('Sending voice message…', () async {
      try {
        await _repo.sendVoice(_other, file, ms, replyTo: quote);
      } finally {
        file.delete().ignore();
      }
    });
  }

  // ------------------------------------------------------------ actions

  Future<void> _menu(Message m) async {
    final mine = m.senderId == _me;
    final r = await showMessageMenu(
      context,
      message: m,
      mine: mine,
      pinned: _chatNow?.pinnedId == m.id,
      myEmoji: m.reactions[_me],
    );
    if (r == null || !mounted) return;
    try {
      final emoji = r.emoji;
      if (emoji != null) {
        await _repo.react(_chatId, m.id, emoji.isEmpty ? null : emoji);
        return;
      }
      switch (r.action!) {
        case MessageAction.reply:
          _reply(m);
        case MessageAction.forward:
          await showForwardSheet(context, send: (to) => _repo.forward(m, to));
        case MessageAction.copy:
          await Clipboard.setData(
            ClipboardData(text: m.isLocation ? m.mapsUri.toString() : m.text),
          );
          _snack('Copied');
        case MessageAction.pin:
          await _repo.pin(_chatId, m);
        case MessageAction.unpin:
          await _repo.unpin(_chatId);
        case MessageAction.deleteAll:
          final ok = await _confirm(
            'Delete for everyone?',
            'This message will be removed for both of you.',
          );
          if (ok) await _repo.deleteForEveryone(_chatId, m);
        case MessageAction.deleteMe:
          await _repo.hideForMe(_chatId, m.id);
      }
    } catch (e) {
      _snack(friendlyError(e));
    }
  }

  Future<bool> _confirm(String title, String text) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('confirm-delete'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: AppColors.like),
            ),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _reactionsTap(Message m) async {
    if (m.reactions.containsKey(_me)) {
      try {
        await _repo.react(_chatId, m.id, null); // tap your emoji = remove
      } catch (e) {
        _snack(friendlyError(e));
      }
    } else {
      await _menu(m);
    }
  }

  Future<void> _call({required bool video}) async {
    final o = widget.other;
    try {
      await Calls.instance.call(
        uid: o.uid,
        username: o.username,
        photoUrl: o.photoUrl,
        video: video,
      );
    } on CallsOff catch (e) {
      _snack(e.toString());
    } catch (e) {
      _snack(friendlyError(e));
    }
  }

  void _showPinned(String id) => jumpTo(id);

  /// v0.10: scroll to a message (reply quote / pinned bar) and flash it.
  /// The list only builds what is near the screen, so it moves one screen
  /// at a time until the message is built, then centres it.
  Future<void> jumpTo(String id) async {
    final idx = _shown.indexWhere((m) => m.id == id);
    if (idx < 0) {
      _snack('This message was deleted or is too old.');
      return;
    }
    for (var tries = 0; tries < 60 && mounted; tries++) {
      final ctx = _keys[id]?.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
        _flash(id);
        return;
      }
      if (!_scroll.hasClients) return;
      // which messages are built now?
      var lo = -1, hi = -1;
      for (var i = 0; i < _shown.length; i++) {
        if (_keys[_shown[i].id]?.currentContext != null) {
          if (lo < 0) lo = i;
          hi = i;
        }
      }
      final pos = _scroll.position;
      final step = pos.viewportDimension * 0.8;
      // reversed list: bigger index = older = bigger offset
      final down = lo >= 0 && idx < lo;
      final target = (pos.pixels + (down ? -step : step)).clamp(
        pos.minScrollExtent,
        pos.maxScrollExtent,
      );
      if (target == pos.pixels && hi >= 0) return; // can't go further
      _scroll.jumpTo(target);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  void _flash(String id) {
    if (!mounted) return;
    setState(() => _flashId = id);
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1300), () {
      if (mounted) setState(() => _flashId = null);
    });
  }

  // ----------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final o = widget.other;
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      o.username,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    ActiveLabel(
                      uid: o.uid,
                      stream:
                          widget.presence ??
                          (_live ? null : Stream<DateTime?>.value(null)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            key: const ValueKey('call-voice'),
            tooltip: 'Voice call',
            onPressed: () => _call(video: false),
            icon: const Icon(Icons.call_outlined),
          ),
          IconButton(
            key: const ValueKey('call-video'),
            tooltip: 'Video call',
            onPressed: () => _call(video: true),
            icon: const Icon(Icons.videocam_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Builder(
            builder: (context) {
              final chat = _chatNow;
              if (chat == null || chat.pinnedId.isEmpty) {
                return const SizedBox.shrink();
              }
              return Material(
                key: const ValueKey('pinned-bar'),
                color: AppColors.surface,
                child: InkWell(
                  onTap: () => _showPinned(chat.pinnedId),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.push_pin,
                          size: 18,
                          color: AppColors.lime,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Pinned message',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.lime,
                                ),
                              ),
                              Text(
                                chat.pinnedText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13.5),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('unpin'),
                          tooltip: 'Unpin',
                          onPressed: () => _repo
                              .unpin(_chatId)
                              .catchError(
                                (Object e) => _snack(friendlyError(e)),
                              ),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          Expanded(
            child: StreamBuilder<List<Message>>(
              stream: _messages,
              builder: (context, snap) {
                if (snap.hasError) return ErrorView(error: snap.error);
                if (!snap.hasData) return const LoadingView();
                final msgs = snap.data!
                    .where((m) => !m.hiddenForUid(_me))
                    .toList();
                _shown = msgs;
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _checkSeen(),
                );
                if (msgs.isEmpty) return _hello(o);
                return ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) {
                    final m = msgs[i];
                    return SwipeToReply(
                      key: _keys.putIfAbsent(m.id, GlobalKey.new),
                      onReply: () => _reply(m),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 350),
                        decoration: BoxDecoration(
                          color: _flashId == m.id
                              ? AppColors.lime.withValues(alpha: 0.16)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: MessageBubble(
                          message: m,
                          mine: m.senderId == _me,
                          myUid: _me,
                          otherName: o.username,
                          tick: _tickFor(m),
                          onLongPress: () => _menu(m),
                          onReactionsTap: () => _reactionsTap(m),
                          onQuoteTap: m.replyTo == null
                              ? null
                              : () => jumpTo(m.replyTo!.id),
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
            _composer(),
        ],
      ),
    );
  }

  Widget _hello(UserProfile o) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Avatar(url: o.photoUrl, name: o.username, size: 84, uid: o.uid),
        const SizedBox(height: 12),
        Text(
          o.username,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        const Text(
          'Say hi 👋',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      ],
    ),
  );

  Widget _composer() {
    final reply = _replyTo;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_busyText != null)
            Padding(
              key: const ValueKey('chat-busy'),
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _busyText!,
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          if (reply != null)
            Container(
              key: const ValueKey('chat-replying'),
              margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              padding: const EdgeInsets.fromLTRB(12, 4, 2, 4),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(Icons.reply_rounded, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          reply.senderId == _me
                              ? 'Replying to yourself'
                              : 'Replying to ${widget.other.username}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppColors.lime,
                          ),
                        ),
                        Text(
                          _quote!.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('chat-reply-cancel'),
                    tooltip: 'Cancel reply',
                    onPressed: () => setState(() => _replyTo = null),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 8, 10),
            child: _recording ? _recordingRow() : _inputRow(),
          ),
        ],
      ),
    );
  }

  Widget _inputRow() {
    return Row(
      children: [
        IconButton(
          key: const ValueKey('chat-attach'),
          tooltip: 'Photo, GIF or location',
          onPressed: _sending ? null : _attach,
          icon: const Icon(Icons.add_circle_outline, size: 26),
        ),
        Expanded(
          child: TextField(
            key: const ValueKey('chat-input'),
            controller: _ctrl,
            focusNode: _focus,
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
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(26),
                borderSide: BorderSide.none,
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
          child: _hadText
              ? IconButton(
                  key: const ValueKey('chat-send'),
                  tooltip: 'Send',
                  onPressed: _sending ? null : _sendText,
                  iconSize: 20,
                  icon: const Icon(Icons.send_rounded, color: Colors.black),
                )
              : IconButton(
                  key: const ValueKey('chat-mic'),
                  tooltip: 'Voice message',
                  onPressed: _sending ? null : _startRecording,
                  iconSize: 22,
                  icon: const Icon(Icons.mic_none_rounded, color: Colors.black),
                ),
        ),
      ],
    );
  }

  Widget _recordingRow() {
    return Row(
      key: const ValueKey('chat-recording'),
      children: [
        IconButton(
          key: const ValueKey('voice-cancel'),
          tooltip: 'Delete',
          onPressed: () => _stopRecording(send: false),
          icon: const Icon(Icons.delete_outline, color: AppColors.like),
        ),
        Expanded(
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(26),
            ),
            child: Row(
              children: [
                const _RecDot(),
                const SizedBox(width: 10),
                Text(
                  formatDuration(_recFor.inMilliseconds),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 10),
                const Flexible(
                  child: Text(
                    'Recording…',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 6),
        Material(
          color: AppColors.lime,
          shape: const CircleBorder(),
          child: IconButton(
            key: const ValueKey('voice-send'),
            tooltip: 'Send voice message',
            onPressed: () => _stopRecording(send: true),
            iconSize: 20,
            icon: const Icon(Icons.send_rounded, color: Colors.black),
          ),
        ),
      ],
    );
  }
}

/// Blinking red dot while recording.
class _RecDot extends StatefulWidget {
  const _RecDot();
  @override
  State<_RecDot> createState() => _RecDotState();
}

class _RecDotState extends State<_RecDot> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.3, end: 1.0).animate(_a),
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: Color(0xFFFF3B4E),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
