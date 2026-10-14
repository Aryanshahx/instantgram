import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/errors.dart';
import '../../shared/widgets/avatar.dart';
import 'call_session.dart';

/// Voice / video call screen (v0.10).
class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.peer,
    required this.video,
    required this.outgoing,
    required this.start,
  });

  final CallPeer peer;
  final bool video;
  final bool outgoing;

  /// Starts / answers the call (the screen shows at once, this runs inside).
  final Future<CallSession> Function() start;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  CallSession? _s;
  String? _error;
  Timer? _clock;
  Timer? _closeTimer;
  bool _bigLocal = false; // tap the small view = swap

  @override
  void initState() {
    super.initState();
    _begin();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _s?.phase == CallPhase.connected) setState(() {});
    });
  }

  Future<void> _begin() async {
    try {
      final s = await widget.start();
      if (!mounted) {
        await s.hangUp();
        await s.disposeViews();
        return;
      }
      s.addListener(_changed);
      setState(() => _s = s);
      _changed();
    } catch (e) {
      if (!mounted) return;
      final text = e is CallGone || e is CallFailed
          ? e.toString()
          : _permissionError(e)
          ? (widget.video
                ? 'Allow camera and microphone to make video calls.'
                : 'Allow the microphone to make calls.')
          : friendlyError(e);
      setState(() => _error = text);
      _closeSoon();
    }
  }

  static bool _permissionError(Object e) {
    final t = '$e'.toLowerCase();
    return t.contains('permission') || t.contains('notallowed');
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_s?.ended == true) _closeSoon();
  }

  void _closeSoon() {
    _closeTimer ??= Timer(const Duration(milliseconds: 1600), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _closeTimer?.cancel();
    final s = _s;
    if (s != null) {
      s.removeListener(_changed);
      if (!s.ended) s.hangUp();
      s.disposeViews();
    }
    super.dispose();
  }

  String get _status {
    if (_error != null) return _error!;
    final s = _s;
    if (s == null) {
      return widget.outgoing ? 'Calling…' : 'Connecting…';
    }
    switch (s.phase) {
      case CallPhase.ringing:
        return 'Ringing…';
      case CallPhase.connecting:
        return 'Connecting…';
      case CallPhase.reconnecting:
        return 'Reconnecting…';
      case CallPhase.ended:
        return s.endReason ?? 'Call ended';
      case CallPhase.connected:
        final d = DateTime.now().difference(s.connectedAt ?? DateTime.now());
        final m = d.inMinutes.toString().padLeft(2, '0');
        final sec = (d.inSeconds % 60).toString().padLeft(2, '0');
        return d.inHours > 0 ? '${d.inHours}:$m:$sec' : '$m:$sec';
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final showVideo =
        widget.video && s != null && !s.ended && s.phase == CallPhase.connected;
    return PopScope(
      // back button does not drop the call by mistake
      canPop: _error != null || s == null || s.ended,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (showVideo && s.hasRemoteVideo)
                RTCVideoView(
                  _bigLocal ? s.localView : s.remoteView,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  mirror: _bigLocal && s.frontCamera,
                )
              else if (widget.video && s != null && !s.ended && s.cameraOn)
                // before connecting: your camera full screen, dimmed
                Opacity(
                  opacity: 0.55,
                  child: RTCVideoView(
                    s.localView,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    mirror: s.frontCamera,
                  ),
                )
              else
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF1B2010), Colors.black],
                    ),
                  ),
                ),
              SafeArea(
                child: Column(
                  children: [
                    const SizedBox(height: 28),
                    if (!(showVideo && s.hasRemoteVideo)) ...[
                      Avatar(
                        url: widget.peer.photoUrl,
                        name: widget.peer.name,
                        size: 110,
                        uid: widget.peer.uid,
                      ),
                      const SizedBox(height: 18),
                    ],
                    Text(
                      widget.peer.name,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        shadows: [Shadow(blurRadius: 8)],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _status,
                      key: const ValueKey('call-status'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 15,
                        color: _error != null
                            ? AppColors.like
                            : Colors.white.withValues(alpha: 0.8),
                        shadows: const [Shadow(blurRadius: 8)],
                      ),
                    ),
                    const Spacer(),
                    _controls(s),
                    const SizedBox(height: 26),
                  ],
                ),
              ),
              if (showVideo && s.hasRemoteVideo && s.cameraOn)
                Positioned(
                  top: MediaQuery.paddingOf(context).top + 12,
                  right: 12,
                  width: 108,
                  height: 160,
                  child: GestureDetector(
                    onTap: () => setState(() => _bigLocal = !_bigLocal),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: RTCVideoView(
                        _bigLocal ? s.remoteView : s.localView,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        mirror: !_bigLocal && s.frontCamera,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls(CallSession? s) {
    final live = s != null && !s.ended && _error == null;
    final buttons = <Widget>[
      _RoundButton(
        key: const ValueKey('call-mute'),
        icon: s?.muted == true ? Icons.mic_off_rounded : Icons.mic_rounded,
        label: s?.muted == true ? 'Unmute' : 'Mute',
        on: s?.muted == true,
        onTap: live ? s.toggleMute : null,
      ),
      if (widget.video) ...[
        _RoundButton(
          key: const ValueKey('call-camera'),
          icon: s?.cameraOn == false
              ? Icons.videocam_off_rounded
              : Icons.videocam_rounded,
          label: 'Camera',
          on: s?.cameraOn == false,
          onTap: live ? s.toggleCamera : null,
        ),
        _RoundButton(
          key: const ValueKey('call-flip'),
          icon: Icons.cameraswitch_rounded,
          label: 'Flip',
          onTap: live && s.cameraOn ? s.switchCamera : null,
        ),
      ],
      _RoundButton(
        key: const ValueKey('call-speaker'),
        icon: s?.speaker == true
            ? Icons.volume_up_rounded
            : Icons.volume_down_rounded,
        label: 'Speaker',
        on: s?.speaker == true,
        onTap: live ? s.toggleSpeaker : null,
      ),
    ];
    return Column(
      children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: buttons),
        const SizedBox(height: 26),
        GestureDetector(
          key: const ValueKey('call-end'),
          onTap: () {
            if (live) {
              s.hangUp();
            } else {
              Navigator.of(context).maybePop();
            }
          },
          child: Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(
              color: Color(0xFFE5484D),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.call_end_rounded,
              color: Colors.white,
              size: 34,
            ),
          ),
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.on = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: on ? Colors.white : Colors.white.withValues(alpha: 0.16),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: 58,
                height: 58,
                child: Icon(icon, color: on ? Colors.black : Colors.white),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ],
      ),
    );
  }
}
