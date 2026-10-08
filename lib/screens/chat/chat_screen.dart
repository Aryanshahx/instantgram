import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/errors.dart';
import '../../core/giphy_key.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../models/chat.dart';
import '../../models/vanish.dart';
import '../../services/chat_service.dart';
import '../../services/location_service.dart';
import '../../services/media_server.dart';
import '../../services/media_service.dart';
import '../../services/photo_edit.dart';
import '../../services/presence_service.dart';
import '../../services/user_service.dart';
import '../../services/voice_recorder.dart';
import '../../core/fonts.dart';
import '../../services/app_prefs.dart';
import '../../widgets/avatar.dart';
import '../../widgets/font_picker.dart';
import '../../widgets/location_card.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/pull_hold.dart';
import '../../widgets/recipient_sheet.dart';
import '../../widgets/share_sheet.dart';
import '../../widgets/state_views.dart';
import '../../widgets/swipe_to_reply.dart';
import '../../core/media_url.dart' show formatDuration;
import '../call/call_screen.dart';
import '../profile/profile_screen.dart';
import 'gif_picker.dart';
import 'image_viewer.dart';
import 'message_actions.dart';
import 'vanish_sheet.dart';

/// A one-to-one chat. Anyone can message anyone: open a profile and tap Message.
///
/// Besides text: photos, GIFs (Giphy), voice notes, your location and shared posts. Swipe a
/// message to reply, hold it to react, forward, pin, copy or delete.

/// Shown instead of the name of an account that was deleted.
const String kUserNotAvailable = 'User not available';

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
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _service = ChatService.instance;
  final _voice = VoiceRecorder();
  late final String _me = UserService.instance.myUid;

  AppUser? _user;

  /// The other account was deleted: history stays readable, nothing can be sent.
  bool _gone = false;

  /// Their profile, live (for "Active now").
  late final Stream<AppUser?> _live = UserService.instance.watchUser(
    widget.otherUid,
  );
  String? _chatId;
  Stream<List<ChatMessage>>? _stream;
  Stream<({String id, String preview, String by})?>? _pinStream;
  Object? _error;
  final List<_Outgoing> _outbox = [];
  String? _seenMessageId;

  ChatMessage? _replying;
  String _busy = '';
  bool _recording = false;
  int _recSeconds = 0;
  Timer? _recTimer;

  List<ChatMessage> _current = const [];
  final Map<String, GlobalKey> _keys = {};

  /// Disappearing messages of this chat ('' = off); pull down and hold to change it.
  String _vanish = Vanish.off;
  StreamSubscription<String>? _vanishSub;
  late final PullHold _pull = PullHold(onFire: _pickVanish);
  String? _highlight;

  @override
  void initState() {
    super.initState();
    _user = widget.user;
    _text.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    final id = _chatId;
    // "after seen" messages I had on screen are gone once I leave
    if (id != null) unawaited(_service.removeSeen(id, _current));
    _vanishSub?.cancel();
    _pull.dispose();
    _recTimer?.cancel();
    _voice.dispose();
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      if (_user == null) {
        UserService.instance.getUser(widget.otherUid).then((u) {
          if (!mounted) return;
          setState(() => u == null ? _gone = true : _user = u);
        });
      }
      unawaited(MediaServer.instance.warmUp());
      final id = await _service.open(widget.otherUid);
      if (!mounted) return;
      setState(() {
        _chatId = id;
        _stream = _service.watchMessages(id);
        _pinStream = _service.watchPin(id);
      });
      _vanishSub?.cancel();
      _vanishSub = _service.watchVanish(id).listen((v) {
        if (mounted && v != _vanish) setState(() => _vanish = v);
      }, onError: (_) {});
      unawaited(_service.sweepExpired(id));
      _service.markSeen(id);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  String _nameOf(String uid) => uid == _me ? 'You' : (_user?.username ?? '');

  ReplyRef? _replyRef() {
    final r = _replying;
    if (r == null) return null;
    return ReplyRef(
      id: r.id,
      senderId: r.senderId,
      kind: r.type,
      preview: r.type == MsgType.text ? r.text : r.preview,
    );
  }

  void _startReply(ChatMessage m) {
    setState(() => _replying = m);
    _focus.requestFocus();
  }

  Future<void> _guard(Future<void> Function() job) async {
    try {
      await job();
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    }
  }

  // ------------------------------------------------------------------ sending

  /// Text goes out at once: the message shows in the chat straight away (the phone keeps it and
  /// delivers it as soon as the network allows), so there is no waiting for the server.
  void _send() {
    final body = _text.text.trim();
    if (body.isEmpty || _chatId == null) return;
    final reply = _replyRef();
    setState(() => _replying = null);
    _text.clear();
    _service
        .send(widget.otherUid, body, replyTo: reply, font: _font)
        .catchError((Object e) {
          if (!mounted) return;
          if (_text.text.isEmpty) _text.text = body; // give the words back
          showToast(context, friendlyError(e));
        });
  }

  Future<void> _sendPhoto(ImageSource source) => _guard(() async {
    final file = await MediaService.pickChatImage(source);
    if (file == null || !mounted) return;
    final reply = _replyRef();
    final out = _Outgoing(file, reply);
    setState(() {
      _outbox.insert(0, out);
      _replying = null;
    });
    unawaited(_upload(out));
  });

  /// Sends one photo of the outbox: it is already on screen with a progress ring while this
  /// runs. The size is read while the bytes go up, and the message is sent before the
  /// service has finished checking the file.
  Future<void> _upload(_Outgoing out) async {
    setState(() {
      out.failed = false;
      out.progress = 0;
    });
    try {
      final sizeTask = PhotoEditor.probeSize(out.file);
      final up = await MediaServer.instance.uploadImage(
        out.file,
        deferConfirm: true,
        onProgress: (p) {
          if (mounted) setState(() => out.progress = p);
        },
      );
      final size = await sizeTask;
      final sent = _service.sendImage(
        widget.otherUid,
        mediaRef: up.ref,
        width: size?.width.round() ?? 0,
        height: size?.height.round() ?? 0,
        replyTo: out.reply,
      );
      if (mounted) setState(() => _outbox.remove(out));
      unawaited(_settle(sent, up));
    } catch (e) {
      if (!mounted) return;
      setState(() => out.failed = true);
      showToast(context, friendlyError(e));
    }
  }

  /// After the message is out: report a send that failed, and take the message back when the
  /// service rejected the photo.
  Future<void> _settle(Future<String> sent, UploadedMedia up) async {
    try {
      final id = await sent;
      try {
        await up.confirmation;
      } catch (e) {
        await _service.discardMine(widget.otherUid, id);
        if (mounted) showToast(context, friendlyError(e));
      }
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    }
  }

  Future<void> _sendGif() async {
    if (kGiphyKey.trim().isEmpty) {
      showToast(context, 'GIFs are not set up yet (no Giphy key in the app).');
      return;
    }
    final g = await showGifPicker(context);
    if (g == null || !mounted) return;
    final reply = _replyRef();
    setState(() => _replying = null);
    await _guard(
      () => _service.sendGif(
        widget.otherUid,
        url: g.url,
        width: g.width,
        height: g.height,
        replyTo: reply,
      ),
    );
  }

  Future<void> _sendLocation() async {
    setState(() => _busy = 'Finding your location...');
    Where? at;
    try {
      at = await currentLocation();
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = '');
    }
    if (at == null || !mounted) return;
    final spot = at;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Send your current location?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 14),
              LocationCard(lat: spot.lat, lng: spot.lng, width: 280),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('confirmLocation'),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Send location'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final reply = _replyRef();
    setState(() => _replying = null);
    await _guard(
      () => _service.sendLocation(
        widget.otherUid,
        lat: spot.lat,
        lng: spot.lng,
        replyTo: reply,
      ),
    );
  }

  Future<void> _attach() async {
    final what = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        Widget item(IconData icon, String label, String id, Color c) => InkWell(
          key: ValueKey('attach_$id'),
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.pop(ctx, id),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: c.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: c, size: 27),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            child: Wrap(
              alignment: WrapAlignment.spaceEvenly,
              spacing: 12,
              runSpacing: 8,
              children: [
                item(
                  Icons.photo_library_rounded,
                  'Photo',
                  'photo',
                  AppTheme.violet,
                ),
                item(
                  Icons.photo_camera_rounded,
                  'Camera',
                  'camera',
                  AppTheme.coral,
                ),
                item(Icons.gif_box_rounded, 'GIF', 'gif', AppTheme.mint),
                item(
                  Icons.location_on_rounded,
                  'Location',
                  'location',
                  const Color(0xFF2E9BFF),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (what == null || !mounted) return;
    switch (what) {
      case 'photo':
        await _sendPhoto(ImageSource.gallery);
      case 'camera':
        await _sendPhoto(ImageSource.camera);
      case 'gif':
        await _sendGif();
      case 'location':
        await _sendLocation();
    }
  }

  // -------------------------------------------------------------------- voice

  Future<void> _startRecording() async {
    if (_chatId == null || _recording) return;
    try {
      await _voice.start();
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
      return;
    }
    if (!mounted) return;
    setState(() {
      _recording = true;
      _recSeconds = 0;
    });
    _recTimer?.cancel();
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recSeconds++);
      if (_recSeconds >= VoiceRecorder.maxSeconds) _finishRecording(send: true);
    });
  }

  Future<void> _finishRecording({required bool send}) async {
    if (!_recording) return;
    _recTimer?.cancel();
    setState(() => _recording = false);
    final rec = await _voice.stop(keep: send);
    if (!send || rec == null || !mounted) return;
    if (rec.seconds < 1) return;
    final reply = _replyRef();
    setState(() {
      _busy = 'Sending voice message...';
      _replying = null;
    });
    await _guard(() async {
      try {
        final up = await MediaServer.instance.uploadVideo(file: rec.file);
        await _service.sendVoice(
          widget.otherUid,
          mediaRef: up.ref,
          seconds: rec.seconds,
          replyTo: reply,
        );
      } finally {
        try {
          await rec.file.delete();
        } on FileSystemException {
          // temporary file; the system cleans it up
        }
        if (mounted) setState(() => _busy = '');
      }
    });
  }

  // ------------------------------------------------------------ message menu

  Future<void> _menu(ChatMessage m) async {
    final id = _chatId;
    if (id == null) return;
    final mine = m.senderId == _me;
    final c = await showMessageMenu(
      context,
      message: m,
      mine: mine,
      myUid: _me,
    );
    if (c == null || !mounted) return;
    if (c.emoji != null) {
      await _guard(() => _service.react(id, m, c.emoji));
      return;
    }
    switch (c.action!) {
      case MessageAction.reply:
        _startReply(m);
      case MessageAction.forward:
        final pick = await pickRecipients(
          context,
          title: 'Forward to',
          actionLabel: 'Forward',
        );
        if (pick == null || !mounted) return;
        await _guard(() async {
          await _service.forward(m, [for (final u in pick.users) u.uid]);
          if (mounted) {
            showToast(
              context,
              pick.users.length == 1
                  ? 'Forwarded to ${pick.users.first.username}'
                  : 'Forwarded to ${pick.users.length} people',
            );
          }
        });
      case MessageAction.copy:
        await copyMessage(m);
        if (mounted) showToast(context, 'Copied');
      case MessageAction.pin:
        await _guard(() => _service.setPinned(id, m, true));
      case MessageAction.unpin:
        await _guard(() => _service.setPinned(id, m, false));
      case MessageAction.deleteForMe:
        await _guard(() => _service.deleteForMe(id, m.id));
      case MessageAction.deleteForAll:
        final ok = await confirm(
          context,
          title: 'Delete for everyone?',
          message: 'It will be replaced by "This message was deleted".',
          confirmLabel: 'Delete',
          destructive: true,
        );
        if (ok && mounted) {
          await _guard(() => _service.deleteForEveryone(id, m));
        }
    }
  }

  void _open(ChatMessage m) {
    switch (m.type) {
      case MsgType.image:
      case MsgType.gif:
        openScreen(context, ImageViewerScreen(url: m.mediaUrl));
      case MsgType.location:
        launchUrl(
          mapsUri(m.lat, m.lng),
          mode: LaunchMode.externalApplication,
        ).catchError((Object _) {
          if (mounted) showToast(context, 'Could not open the map.');
          return false;
        });
      case MsgType.post:
        openSharedPost(context, m);
      case MsgType.call:
        _call(video: m.callVideo);
    }
  }

  // --------------------------------------------------------------- scrolling

  Future<bool> _reveal(String id) async {
    final ctx = _keys[id]?.currentContext;
    if (ctx == null) return false;
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 280),
      alignment: 0.5,
    );
    return true;
  }

  Future<void> _jumpTo(String id) async {
    final i = _current.indexWhere((m) => m.id == id);
    if (i < 0) {
      showToast(context, 'That message is too far back.');
      return;
    }
    var ok = await _reveal(id);
    if (!ok && _scroll.hasClients) {
      _scroll.jumpTo((i * 96.0).clamp(0.0, _scroll.position.maxScrollExtent));
      await WidgetsBinding.instance.endOfFrame;
      ok = await _reveal(id);
    }
    if (!ok || !mounted) return;
    setState(() => _highlight = id);
    Timer(const Duration(milliseconds: 1400), () {
      if (mounted && _highlight == id) setState(() => _highlight = null);
    });
  }

  void _call({required bool video}) => startCall(
    context,
    peerUid: widget.otherUid,
    peerName: _user?.username ?? 'Call',
    peerPhoto: _user?.photoUrl ?? '',
    video: video,
  );

  void _openProfile() =>
      openScreen(context, ProfileScreen(uid: widget.otherUid));

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final u = _user;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _gone ? null : _openProfile,
          child: Row(
            children: [
              UserAvatar(
                url: u?.photoUrl ?? '',
                name: u?.username ?? '',
                radius: 18,
                uid: widget.otherUid,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _gone ? kUserNotAvailable : (u?.username ?? '...'),
                      key: const ValueKey('chatTitle'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    if (!_gone)
                      StreamBuilder<AppUser?>(
                        stream: _live,
                        builder: (context, snap) {
                          final label = presenceLabel(
                            snap.data?.lastActive ?? u?.lastActive,
                            DateTime.now(),
                          );
                          if (label.isEmpty) return const SizedBox.shrink();
                          return Text(
                            label,
                            key: const ValueKey('chatPresence'),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: context.muted,
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (!_gone) ...[
            IconButton(
              key: const ValueKey('voiceCall'),
              tooltip: 'Voice call',
              icon: const Icon(Icons.call_rounded),
              onPressed: () => _call(video: false),
            ),
            IconButton(
              key: const ValueKey('videoCall'),
              tooltip: 'Video call',
              icon: const Icon(Icons.videocam_rounded),
              onPressed: () => _call(video: true),
            ),
          ],
          const SizedBox(width: 4),
        ],
      ),
      body: ContentWidth(
        maxWidth: 680,
        child: Column(
          children: [
            _pinBanner(context),
            if (_vanish.isNotEmpty) _vanishBanner(context),
            Expanded(
              child: Stack(
                children: [
                  NotificationListener<ScrollNotification>(
                    onNotification: _gone ? null : _pull.handle,
                    child: _messages(context),
                  ),
                  _pullHint(context),
                ],
              ),
            ),
            if (_busy.isNotEmpty) _busyBar(context),
            if (_replying != null && !_gone) _replyBar(context),
            _gone ? _goneBar(context) : _composer(context),
          ],
        ),
      ),
    );
  }

  Widget _pinBanner(BuildContext context) {
    final s = _pinStream;
    if (s == null) return const SizedBox.shrink();
    return StreamBuilder<({String id, String preview, String by})?>(
      stream: s,
      builder: (context, snap) {
        final pin = snap.data;
        if (pin == null) return const SizedBox.shrink();
        return Material(
          color: context.cardHigh,
          child: InkWell(
            key: const ValueKey('pinBanner'),
            onTap: () => _jumpTo(pin.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Row(
                children: [
                  const Icon(Icons.push_pin_rounded, size: 17),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Pinned by ${_nameOf(pin.by).toLowerCase() == 'you' ? 'you' : _nameOf(pin.by)}',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: context.muted,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          pin.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _busyBar(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
    child: Row(
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
        const SizedBox(width: 10),
        Text(_busy, style: TextStyle(color: context.muted, fontSize: 13)),
      ],
    ),
  );

  Widget _replyBar(BuildContext context) {
    final r = _replying!;
    return Container(
      key: const ValueKey('replyBar'),
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: context.cardHigh,
        borderRadius: BorderRadius.circular(14),
        border: const Border(
          left: BorderSide(color: AppTheme.violet, width: 4),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Replying to ${_nameOf(r.senderId)}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  r.type == MsgType.text ? r.text : r.preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: context.muted, fontSize: 13),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('cancelReply'),
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: () => setState(() => _replying = null),
          ),
        ],
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
        final all = snap.data;
        if (all == null) return const CenteredLoader();
        final now = DateTime.now();
        final msgs = [
          for (final m in all)
            if (m.visibleFor(_me) && !m.expired(now)) m,
        ];
        _current = msgs;
        if (msgs.isEmpty && _outbox.isEmpty) {
          // still scrollable, so pull down and hold works in an empty chat too
          return LayoutBuilder(
            builder: (context, c) => SingleChildScrollView(
              reverse: true,
              physics: const AlwaysScrollableScrollPhysics(),
              child: SizedBox(
                height: c.maxHeight,
                child: EmptyState(
                  icon: Icons.waving_hand_rounded,
                  title: 'Say hi',
                  subtitle:
                      'Send the first message to ${_user?.username ?? 'them'}.',
                ),
              ),
            ),
          );
        }
        // someone else's new message is on screen: mark the chat as read
        final newest = msgs.isEmpty ? null : msgs.first;
        if (newest != null &&
            newest.senderId != _me &&
            newest.id != _seenMessageId) {
          _seenMessageId = newest.id;
          final id = _chatId;
          if (id != null) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _service.markSeen(id),
            );
          }
        }
        return ListView.builder(
          controller: _scroll,
          reverse: true,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          itemCount: _outbox.length + msgs.length,
          itemBuilder: (context, i) => i < _outbox.length
              ? _OutgoingBubble(
                  key: ObjectKey(_outbox[i]),
                  item: _outbox[i],
                  onRetry: () => _upload(_outbox[i]),
                  onDiscard: () => setState(() => _outbox.removeAt(i)),
                )
              : _item(msgs[i - _outbox.length]),
        );
      },
    );
  }

  Widget _item(ChatMessage m) {
    if (m.type == MsgType.system) return _systemLine(context, m);
    final mine = m.senderId == _me;
    return KeyedSubtree(
      key: _keys.putIfAbsent(m.id, GlobalKey.new),
      child: SwipeToReply(
        enabled: !m.deleted && m.type != MsgType.call,
        onReply: () => _startReply(m),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onLongPress: () => _menu(m),
          child: MessageBubble(
            message: m,
            text: m.text,
            mine: mine,
            myUid: _me,
            time: chatTime(m.createdAt),
            pending: m.pending,
            nameOf: _nameOf,
            highlight: _highlight == m.id,
            onOpen: () => _open(m),
            onReact: (e) {
              final id = _chatId;
              if (id != null) _guard(() => _service.react(id, m, e));
            },
            onReplyTap: m.replyTo == null ? null : () => _jumpTo(m.replyTo!.id),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------- disappearing messages

  Future<void> _pickVanish() async {
    if (_gone || _chatId == null || !mounted) return;
    final pick = await showVanishPicker(context, current: _vanish);
    if (pick == null || pick == _vanish || !mounted) return;
    await _guard(() async {
      final me = await UserService.instance.getUser(_me);
      await _service.setVanish(
        widget.otherUid,
        pick,
        myName: me?.username ?? 'Someone',
      );
      if (mounted) setState(() => _vanish = pick);
    });
  }

  Widget _vanishBanner(BuildContext context) => Material(
    key: const ValueKey('vanishBanner'),
    color: context.cardHigh,
    child: InkWell(
      onTap: _pickVanish,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.timer_outlined, size: 17),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Disappearing messages: ${Vanish.label(_vanish).toLowerCase()}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Text('Change', style: TextStyle(color: context.muted)),
          ],
        ),
      ),
    ),
  );

  /// While pulling down: "keep holding" with a little progress ring.
  Widget _pullHint(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: _pull.progress,
    builder: (context, p, _) {
      if (p <= 0) return const SizedBox.shrink();
      return Positioned(
        top: 10,
        left: 0,
        right: 0,
        child: Center(
          child: Container(
            key: const ValueKey('vanishPullHint'),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: context.cardHigh,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(value: p, strokeWidth: 2.5),
                ),
                const SizedBox(width: 10),
                Text(
                  p < 1
                      ? 'Pull down for disappearing messages'
                      : 'Keep holding…',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _systemLine(BuildContext context, ChatMessage m) => Padding(
    key: _keys.putIfAbsent(m.id, GlobalKey.new),
    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 24),
    child: Text(
      m.text,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: context.muted,
      ),
    ),
  );

  Widget _goneBar(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      key: const ValueKey('userGoneBar'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: context.cardHigh,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        'This account was deleted. You can still read your messages.',
        textAlign: TextAlign.center,
        style: TextStyle(color: context.muted, fontWeight: FontWeight.w600),
      ),
    ),
  );

  /// Font for my text messages (kept for next time).
  String _font = cleanFontId(AppPrefs.instance.chatFont);
  bool _fontRow = false;

  void _setFont(String f) {
    setState(() => _font = f);
    AppPrefs.instance.chatFont = f;
  }

  Widget _composer(BuildContext context) {
    if (_recording) return _recordingBar(context);
    final hasText = _text.text.trim().isNotEmpty;
    final ready = _chatId != null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_fontRow)
              FontChipRow(
                key: const ValueKey('chatFontRow'),
                keyPrefix: 'chatFont',
                selected: _font,
                onChanged: _setFont,
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  width: 46,
                  height: 50,
                  child: IconButton(
                    key: const ValueKey('attachButton'),
                    onPressed: ready && _busy.isEmpty ? _attach : null,
                    icon: const Icon(Icons.add_circle_rounded, size: 30),
                  ),
                ),
                Expanded(
                  child: TextField(
                    key: const ValueKey('chatInput'),
                    controller: _text,
                    focusNode: _focus,
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
                    style: maybeAppFont(_font, const TextStyle(fontSize: 16)),
                    decoration: InputDecoration(
                      hintText: 'Message...',
                      suffixIcon: IconButton(
                        key: const ValueKey('chatFontButton'),
                        tooltip: 'Font',
                        onPressed: () => setState(() => _fontRow = !_fontRow),
                        icon: Icon(
                          Icons.text_fields_rounded,
                          color: _font.isNotEmpty || _fontRow
                              ? context.accentInk
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  key: ValueKey(hasText ? 'sendButton' : 'micButton'),
                  onTap: hasText
                      ? (ready ? _send : null)
                      : (ready && _busy.isEmpty ? _startRecording : null),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: ready ? AppTheme.volt : context.cardHigh,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      hasText ? Icons.send_rounded : Icons.mic_rounded,
                      size: 23,
                      color: ready ? AppTheme.ink : context.muted,
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

  Widget _recordingBar(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 12, 10),
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('recordCancel'),
              onPressed: () => _finishRecording(send: false),
              icon: const Icon(Icons.delete_outline_rounded, size: 27),
              color: AppTheme.coral,
            ),
            Expanded(
              child: Container(
                height: 50,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: context.cardHigh,
                  borderRadius: BorderRadius.circular(25),
                ),
                child: Row(
                  children: [
                    const _BlinkDot(),
                    const SizedBox(width: 10),
                    Text(
                      formatDuration(_recSeconds),
                      key: const ValueKey('recordTimer'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Recording...',
                        style: TextStyle(color: context.muted),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              key: const ValueKey('recordSend'),
              onTap: () => _finishRecording(send: true),
              child: Container(
                width: 50,
                height: 50,
                decoration: const BoxDecoration(
                  color: AppTheme.volt,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.send_rounded,
                  size: 23,
                  color: AppTheme.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BlinkDot extends StatefulWidget {
  const _BlinkDot();

  @override
  State<_BlinkDot> createState() => _BlinkDotState();
}

class _BlinkDotState extends State<_BlinkDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween<double>(begin: 0.25, end: 1).animate(_c),
    child: Container(
      width: 11,
      height: 11,
      decoration: const BoxDecoration(
        color: AppTheme.coral,
        shape: BoxShape.circle,
      ),
    ),
  );
}

/// A photo that is still going up. It is shown in the chat at once.
class _Outgoing {
  _Outgoing(this.file, this.reply);
  final File file;
  final ReplyRef? reply;
  double progress = 0;
  bool failed = false;
}

class _OutgoingBubble extends StatelessWidget {
  const _OutgoingBubble({
    super.key,
    required this.item,
    required this.onRetry,
    required this.onDiscard,
  });

  final _Outgoing item;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Align(
        alignment: Alignment.centerRight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                key: const ValueKey('outgoingPhoto'),
                width: 220,
                height: 260,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(
                      item.file,
                      fit: BoxFit.cover,
                      cacheWidth: 600,
                      errorBuilder: (_, _, _) =>
                          ColoredBox(color: context.softFill),
                    ),
                    ColoredBox(color: Colors.black.withValues(alpha: 0.28)),
                    Center(
                      child: item.failed
                          ? const Icon(
                              Icons.error_outline_rounded,
                              color: Colors.white,
                              size: 40,
                            )
                          : SizedBox(
                              width: 44,
                              height: 44,
                              child: CircularProgressIndicator(
                                value: item.progress > 0 && item.progress < 1
                                    ? item.progress
                                    : null,
                                strokeWidth: 3.5,
                                color: Colors.white,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            if (item.failed)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    key: const ValueKey('retryPhoto'),
                    onPressed: onRetry,
                    child: const Text('Not sent. Tap to retry'),
                  ),
                  IconButton(
                    key: const ValueKey('discardPhoto'),
                    onPressed: onDiscard,
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ],
              )
            else
              Text(
                'Sending...',
                style: TextStyle(color: context.muted, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }
}
