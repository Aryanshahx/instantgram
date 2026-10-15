import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../../core/services/calls.dart';
import '../../../core/services/chat_prefs.dart';
import '../../../core/services/content_filter.dart';
import '../../../core/services/location_service.dart';
import '../../../core/services/media_service.dart';
import '../../../core/services/presence.dart';
import '../../../core/services/server_clock.dart';
import '../../../core/services/system_settings.dart';
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
import '../data/typing_tracker.dart';
import '../../../shared/widgets/verified_badge.dart';

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
  final Stream<PresenceState?>? presence;

  /// Tests: replace Firestore.
  final Stream<List<Message>>? messages;
  final Stream<Chat?>? chat;
  final String? myUid;

  /// Longest voice message.
  static const Duration maxVoice = Duration(minutes: 5);

  /// v0.11: the chat on screen now (no notification banner for it).
  static String? openChatId;

  /// v0.11: how far to slide up (and hold) to switch disappearing messages.
  static const double pullToVanish = 110;

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

  // v0.11 disappearing messages
  bool _gotChat = false;
  DateTime? _seenBefore; // when you last saw this chat (before opening it)
  final Map<String, Message> _vanishShown = {}; // "once seen" ones you saw
  List<Message> _all = const [];
  DateTime _lastSweep = DateTime(2000);
  Timer? _expiryTick;
  String? _modeNow; // set right away when you change it
  // v0.13 typing
  DateTime _typingSent = DateTime(2000);
  bool _typingOn = false;
  Timer? _typingExpiry;
  double _pull = 0; // slide up & hold distance
  bool _armed = false;

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
    ChatDetailScreen.openChatId = _chatId;
    if (_live) SystemSettings.clearChatNotification(_chatId);
    _chatSub = _chat.listen((c) {
      if (!mounted) return;
      if (!_gotChat) {
        _gotChat = true;
        _seenBefore = c?.seenAt(_me);
      }
      if (c != null) _repo.rememberMode(_chatId, c.disappear);
      setState(() {
        _chatNow = c;
        _modeNow = null;
      });
      // v0.14: hide "typing…" when no new signal comes
      _armTyping();
      _checkSeen();
    }, onError: (Object e) => debugPrint('chat: $e'));
    _life = AppLifecycleListener(onResume: _checkSeen, onHide: _stopTyping);
    // 24 h / 7 day messages go away while you look
    _expiryTick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _all.any((m) => m.expireAt != null)) setState(() {});
    });
  }

  // ------------------------------------------------ v0.11 disappearing

  /// v0.14: the chat's mode again (the same for both people).
  String get _mode => _modeNow ?? _chatNow?.disappear ?? Disappear.off;

  Future<void> _setMode(String mode) async {
    if (mode == _mode) return;
    setState(() => _modeNow = mode);
    if (!_live) return;
    try {
      await _repo.setDisappear(_other, mode);
    } catch (e) {
      if (mounted) setState(() => _modeNow = null);
      _snack(friendlyError(e));
    }
  }

  // ------------------------------------------------------- v0.13 typing

  bool get _otherTyping {
    final c = _chatNow;
    if (c == null) return false;
    return TypingTracker.instance.isTyping(
      c,
      widget.other.uid,
      serverNow: ServerClock.now(),
    );
  }

  void _armTyping() {
    _typingExpiry?.cancel();
    final c = _chatNow;
    if (c == null || !_otherTyping) return;
    final left = TypingTracker.instance.left(c, widget.other.uid);
    if (left == null) return;
    _typingExpiry = Timer(left + const Duration(milliseconds: 50), () {
      if (mounted) setState(() {});
    });
  }

  void _stopTyping() {
    if (!_typingOn) return;
    _typingOn = false;
    _typingSent = DateTime(2000);
    if (_live) _repo.setTyping(_chatId, false);
  }

  /// Slide up and hold, then let go: on (24 h) <-> off.
  void _toggleMode() {
    final next = _mode == Disappear.off ? Disappear.standard : Disappear.off;
    HapticFeedback.mediumImpact();
    // v0.14: no pop-up at the bottom (the bar in the chat shows it)
    _setMode(next);
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final atBottom = n.metrics.pixels <= n.metrics.minScrollExtent + 0.5;
    if (n is OverscrollNotification && n.dragDetails != null && atBottom) {
      // reversed list: sliding up past the newest message = negative
      if (n.overscroll < 0) _addPull(-n.overscroll);
    } else if (n is ScrollUpdateNotification &&
        n.dragDetails != null &&
        n.metrics.pixels < n.metrics.minScrollExtent) {
      _addPull(-(n.scrollDelta ?? 0)); // bouncy phones
    } else if (n is ScrollUpdateNotification &&
        n.dragDetails != null &&
        (n.scrollDelta ?? 0) > 0 &&
        _pull > 0) {
      _setPull(0); // moved back down
    } else if (n is ScrollEndNotification) {
      if (_armed) _toggleMode();
      _setPull(0);
    }
    return false;
  }

  void _addPull(double d) => _setPull((_pull + d).clamp(0, 400));

  void _setPull(double v) {
    final armed = v >= ChatDetailScreen.pullToVanish;
    if (armed && !_armed) HapticFeedback.selectionClick();
    if (v == _pull && armed == _armed) return;
    setState(() {
      _pull = v;
      _armed = armed;
    });
  }

  /// Hides / deletes messages that are gone.
  List<Message> _visible(List<Message> all) {
    _all = all;
    final prefs = ChatPrefs.instance.value.value;
    final msgs = ChatRepository.visible(
      all,
      me: _me,
      clearedAt: prefs.clearedAt(_chatId),
      seenBefore: _seenBefore,
    );
    for (final m in msgs) {
      if (m.vanish && m.senderId != _me && !m.pending) _vanishShown[m.id] = m;
    }
    if (_live && DateTime.now().difference(_lastSweep).inSeconds > 20) {
      final seen = _seenBefore;
      final stale = all.where(
        (m) =>
            m.vanish &&
            m.senderId != _me &&
            seen != null &&
            !m.pending &&
            !m.createdAt.isAfter(seen),
      );
      if (stale.isNotEmpty || all.length != msgs.length) {
        _lastSweep = DateTime.now();
        _repo.sweep(_chatId, all, seenVanish: stale.toList());
      }
    }
    return msgs;
  }

  Future<void> _chooseMode() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        // scrolls on small screens (no overflow)
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 2),
                child: Text(
                  'Disappearing messages',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Text(
                  'New messages disappear for both of you. Tip: slide up and '
                  'hold in the chat to switch it on or off.',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ),
              for (final mode in Disappear.all)
                ListTile(
                  key: ValueKey('disappear-$mode'),
                  dense: true,
                  leading: Icon(
                    mode == _mode
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: mode == _mode
                        ? AppColors.lime
                        : AppColors.textSecondary,
                  ),
                  title: Text(
                    Disappear.label(mode),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () => Navigator.pop(ctx, mode),
                ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) await _setMode(picked);
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
    // tell the other person "typing…" (v0.14: right away, then every 3 s)
    if (!_live) return;
    if (has) {
      final now = DateTime.now();
      if (now.difference(_typingSent) >= TypingTracker.ping) {
        _typingSent = now;
        _typingOn = true;
        _repo.setTyping(_chatId, true);
      }
    } else {
      _stopTyping();
    }
  }

  @override
  void dispose() {
    if (ChatDetailScreen.openChatId == _chatId) {
      ChatDetailScreen.openChatId = null;
    }
    // "once seen": you saw them, now they disappear
    if (_live && _vanishShown.isNotEmpty) {
      _repo.sweep(_chatId, const [], seenVanish: _vanishShown.values.toList());
    }
    _expiryTick?.cancel();
    _typingExpiry?.cancel();
    _stopTyping();
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
    // the message itself clears "typing…" (no extra write)
    _typingOn = false;
    _typingSent = DateTime(2000);
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
                    NameBadge(
                      o.username,
                      uid: o.uid,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (_otherTyping)
                      const Text(
                        'typing…',
                        key: ValueKey('chat-typing'),
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.lime,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    else
                      ActiveLabel(
                        uid: o.uid,
                        stream:
                            widget.presence ??
                            (_live ? null : Stream<PresenceState?>.value(null)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            key: const ValueKey('disappear-btn'),
            tooltip: 'Disappearing messages',
            onPressed: _chooseMode,
            icon: Icon(
              Icons.timer_outlined,
              color: _mode == Disappear.off ? null : AppColors.lime,
            ),
          ),
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
                final msgs = _visible(snap.data!);
                _shown = msgs;
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _checkSeen(),
                );
                if (msgs.isEmpty) return _hello(o);
                final list = ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  // v0.11: also short chats can be slid up
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) {
                    final m = msgs[i];
                    if (m.isSystem) {
                      return SystemNote(
                        key: _keys.putIfAbsent(m.id, GlobalKey.new),
                        text: m.text,
                        onTap: _chooseMode,
                      );
                    }
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
                          tick: m.isCall ? MessageTick.none : _tickFor(m),
                          onLongPress: () => _menu(m),
                          onReactionsTap: () => _reactionsTap(m),
                          onQuoteTap: m.replyTo == null
                              ? null
                              : () => jumpTo(m.replyTo!.id),
                          onCallTap: m.isCall
                              ? () => _call(video: m.video)
                              : null,
                        ),
                      ),
                    );
                  },
                );
                return NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: Stack(
                    children: [
                      Positioned.fill(child: list),
                      if (_pull > 0) _pullHint(),
                    ],
                  ),
                );
              },
            ),
          ),
          if (_otherTyping) TypingBubble(name: o.username),
          if (_mode != Disappear.off) _modeBar(),
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

  /// "Slide up to turn on disappearing messages" while you pull.
  Widget _pullHint() {
    final p = (_pull / ChatDetailScreen.pullToVanish).clamp(0.0, 1.0);
    final on = _mode != Disappear.off;
    final text = _armed
        ? (on
              ? 'Release to turn off disappearing messages'
              : 'Release to turn on disappearing messages')
        : (on
              ? 'Slide up to turn off disappearing messages'
              : 'Slide up to turn on disappearing messages');
    return Positioned(
      left: 0,
      right: 0,
      bottom: 8 + 30 * p,
      child: IgnorePointer(
        child: Opacity(
          opacity: (0.3 + p * 0.7).clamp(0.0, 1.0),
          child: Column(
            key: const ValueKey('vanish-hint'),
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 38,
                height: 38,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: p,
                      strokeWidth: 2.5,
                      color: AppColors.lime,
                      backgroundColor: AppColors.border,
                    ),
                    Icon(
                      Icons.timer_outlined,
                      size: 20,
                      color: _armed ? AppColors.lime : AppColors.textPrimary,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                text,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: _armed ? AppColors.lime : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Thin bar above the message box while disappearing messages are on.
  Widget _modeBar() => Material(
    key: const ValueKey('disappear-bar'),
    color: AppColors.surface,
    child: InkWell(
      onTap: _chooseMode,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.timer_outlined, size: 15, color: AppColors.lime),
            const SizedBox(width: 6),
            Text(
              'Disappearing messages · ${Disappear.label(_mode)}',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.lime,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _hello(UserProfile o) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Avatar(url: o.photoUrl, name: o.username, size: 84, uid: o.uid),
        const SizedBox(height: 12),
        NameBadge(
          o.username,
          uid: o.uid,
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
