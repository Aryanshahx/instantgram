import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/call.dart';
import '../../services/call_engine.dart';
import '../../services/call_service.dart';
import '../../widgets/avatar.dart';

/// Opens a voice or video call to [peerUid] (the call buttons in the chat).
Future<void> startCall(
  BuildContext context, {
  required String peerUid,
  required String peerName,
  String peerPhoto = '',
  required bool video,
}) async {
  if (!CallDeps.configured()) {
    showToast(
      context,
      'Calls are not set up yet. Run: bash tools/set_agora_id.sh YOUR_APP_ID',
    );
    return;
  }
  if (CallService.instance.busy) {
    showToast(context, 'You are already in a call.');
    return;
  }
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => CallScreen(
        peerUid: peerUid,
        peerName: peerName,
        peerPhoto: peerPhoto,
        video: video,
      ),
    ),
  );
}

/// The call itself. Without [existing] this phone is the caller and rings the other person;
/// with it (after "Accept") this phone answers.
class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.peerUid,
    required this.peerName,
    this.peerPhoto = '',
    required this.video,
    this.existing,
  });

  final String peerUid;
  final String peerName;
  final String peerPhoto;
  final bool video;
  final CallInfo? existing;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _service = CallService.instance;
  late final CallEngine _engine = CallDeps.engine();
  CallTone? _tone;
  StreamSubscription<CallInfo?>? _watch;
  Timer? _ringTimeout;
  Timer? _ticker;

  CallInfo? _call;
  bool get _isCaller => widget.existing == null;

  bool _connected = false;
  bool _finishing = false;
  bool _remoteOver = false;
  bool _failed = false;
  bool _muted = false;
  late bool _speaker = widget.video;
  bool _cameraOn = true;
  int _seconds = 0;
  String _status = 'Starting...';
  String? _problem;

  @override
  void initState() {
    super.initState();
    _service.busy = true;
    CallDeps.screenOn(true);
    _engine.remoteJoined.addListener(_onRemoteJoined);
    _engine.remoteLeft.addListener(_onRemoteLeft);
    _engine.remoteVideoOn.addListener(_refresh);
    _engine.error.addListener(_refresh);
    unawaited(_start());
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    final allowed = await CallDeps.permissions(widget.video);
    if (!mounted || _finishing) return;
    if (!allowed) {
      _problem = widget.video
          ? 'Allow the microphone and camera in Settings to make calls.'
          : 'Allow the microphone in Settings to make calls.';
      setState(() => _status = 'No permission');
      if (!_isCaller) {
        await _service.setStatus(widget.existing!.id, CallStatus.declined);
      }
      _closeLater();
      return;
    }
    try {
      if (_isCaller) {
        setState(() => _status = 'Calling...');
        _call = await _service.place(widget.peerUid, video: widget.video);
        _tone = CallTone(incoming: false)..start();
        _ringTimeout = Timer(kRingTimeout, () {
          if (!_connected) _finish(CallStatus.missed);
        });
      } else {
        _call = widget.existing;
        setState(() => _status = 'Connecting...');
        await _service.setStatus(_call!.id, CallStatus.accepted);
      }
      if (!mounted || _finishing) return;
      _watch = _service.watch(_call!.id).listen(_onCall);
      await _engine.join(channel: _call!.channel, video: widget.video);
      await _engine.setSpeaker(_speaker);
      if (mounted && _isCaller && !_connected) {
        setState(() => _status = 'Ringing...');
      }
    } catch (e) {
      if (!mounted) return;
      _failed = true;
      _problem =
          'Could not start the call. Check your connection and try again.';
      setState(() => _status = 'Call failed');
      if (_call != null) await _service.setStatus(_call!.id, CallStatus.ended);
      _closeLater();
    }
  }

  void _closeLater() {
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted && !_finishing) _finish(CallStatus.ended, fromRemote: true);
    });
  }

  void _onCall(CallInfo? c) {
    if (c == null || _finishing) return;
    if (CallStatus.isOver(c.status)) {
      _remoteOver = true;
      if (c.status == CallStatus.declined) setState(() => _status = 'Declined');
      _finish(c.status, fromRemote: true);
    }
  }

  void _onRemoteJoined() {
    if (!_engine.remoteJoined.value || _connected || _finishing) return;
    _connected = true;
    _ringTimeout?.cancel();
    _tone?.stop();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
    setState(() => _status = '');
  }

  void _onRemoteLeft() {
    if (_engine.remoteLeft.value && !_finishing) {
      _finish(CallStatus.ended);
    }
  }

  /// The red button: cancels a ring that was not answered, or ends the call.
  void _hangUp() {
    if (_finishing) return;
    _finish(_isCaller && !_connected ? CallStatus.missed : CallStatus.ended);
  }

  Future<void> _finish(String status, {bool fromRemote = false}) async {
    if (_finishing) return;
    _finishing = true;
    _ringTimeout?.cancel();
    _ticker?.cancel();
    _watch?.cancel();
    unawaited(_tone?.stop());
    final call = _call;
    final secs = _seconds;
    final wasConnected = _connected;
    if (mounted) setState(() => _status = 'Call ended');
    if (call != null && !fromRemote && !_remoteOver) {
      await _service.setStatus(call.id, status);
    }
    await _engine.leave();
    if (call != null && _isCaller && !_failed) {
      // only the caller writes the "Voice call 2:31" line, so it appears once
      var logStatus = status;
      if (logStatus == CallStatus.ended && !wasConnected) {
        logStatus = CallStatus.missed;
      }
      try {
        await CallDeps.writeLog(
          widget.peerUid,
          widget.video,
          logStatus,
          wasConnected ? secs : 0,
        );
      } catch (_) {
        // the call itself worked; the chat line is a nice extra
      }
    }
    _service.busy = false;
    CallDeps.screenOn(false);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _ringTimeout?.cancel();
    _ticker?.cancel();
    _watch?.cancel();
    unawaited(_tone?.stop());
    _engine.remoteJoined.removeListener(_onRemoteJoined);
    _engine.remoteLeft.removeListener(_onRemoteLeft);
    _engine.remoteVideoOn.removeListener(_refresh);
    _engine.error.removeListener(_refresh);
    if (!_finishing) {
      // closed in some other way: still free the microphone and camera
      final call = _call;
      if (call != null) {
        unawaited(
          _service.setStatus(
            call.id,
            _isCaller && !_connected ? CallStatus.missed : CallStatus.ended,
          ),
        );
      }
      unawaited(_engine.leave());
      _service.busy = false;
      CallDeps.screenOn(false);
    }
    super.dispose();
  }

  // ---------------------------------------------------------------- build

  String get _subtitle {
    if (_problem != null) return _problem!;
    final err = _engine.error.value;
    if (err != null) return err;
    if (_connected) return formatCallTime(_seconds);
    return _status;
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    final showRemote = video && _engine.remoteVideoOn.value && _connected;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _hangUp();
      },
      child: Scaffold(
        backgroundColor: AppTheme.ink,
        body: Stack(
          fit: StackFit.expand,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF1A1440), AppTheme.ink],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
            if (showRemote)
              KeyedSubtree(
                key: const ValueKey('remoteVideo'),
                child: _engine.remoteView(),
              ),
            if (!showRemote) _centerCard(),
            if (showRemote) _topBar(),
            if (video && _cameraOn) _pip(),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                minimum: const EdgeInsets.only(bottom: 22),
                child: _controls(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _centerCard() => SafeArea(
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          UserAvatar(
            url: widget.peerPhoto,
            name: widget.peerName,
            radius: 64,
            ring: _connected,
          ),
          const SizedBox(height: 22),
          Text(
            widget.peerName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _subtitle,
              key: const ValueKey('callStatus'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _problem != null || _engine.error.value != null
                    ? AppTheme.coral
                    : Colors.white70,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_connected && widget.video)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Their camera is off',
                style: TextStyle(color: Colors.white54),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _topBar() => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Align(
        alignment: Alignment.topLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.peerName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
              ),
            ),
            Text(
              _subtitle,
              key: const ValueKey('callStatus'),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _pip() => SafeArea(
    child: Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 14, 16, 0),
        child: ClipRRect(
          key: const ValueKey('localVideo'),
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(width: 104, height: 150, child: _engine.localView()),
        ),
      ),
    ),
  );

  Widget _controls() {
    final video = widget.video;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _round(
          key: 'callMute',
          icon: _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
          on: _muted,
          label: 'Mute',
          onTap: () {
            setState(() => _muted = !_muted);
            _engine.setMuted(_muted);
          },
        ),
        if (video)
          _round(
            key: 'callCamera',
            icon: _cameraOn
                ? Icons.videocam_rounded
                : Icons.videocam_off_rounded,
            on: !_cameraOn,
            label: 'Camera',
            onTap: () {
              setState(() => _cameraOn = !_cameraOn);
              _engine.setCameraOn(_cameraOn);
            },
          ),
        if (video)
          _round(
            key: 'callFlip',
            icon: Icons.flip_camera_android_rounded,
            label: 'Flip',
            onTap: _engine.switchCamera,
          ),
        _round(
          key: 'callSpeaker',
          icon: _speaker ? Icons.volume_up_rounded : Icons.volume_down_rounded,
          on: _speaker,
          label: 'Speaker',
          onTap: () {
            setState(() => _speaker = !_speaker);
            _engine.setSpeaker(_speaker);
          },
        ),
        _round(
          key: 'callEnd',
          icon: Icons.call_end_rounded,
          label: 'End',
          bg: AppTheme.coral,
          fg: Colors.white,
          onTap: _hangUp,
        ),
      ],
    );
  }

  Widget _round({
    required String key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool on = false,
    Color? bg,
    Color? fg,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 9),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: bg ?? (on ? Colors.white : Colors.white24),
          shape: const CircleBorder(),
          child: InkWell(
            key: ValueKey(key),
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 58,
              height: 58,
              child: Icon(
                icon,
                color: fg ?? (on ? AppTheme.ink : Colors.white),
                size: 27,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 11.5),
        ),
      ],
    ),
  );
}
