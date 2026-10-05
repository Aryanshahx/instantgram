import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/app_user.dart';
import '../../models/call.dart';
import '../../services/call_service.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
import 'call_screen.dart';

/// Full-screen "X is calling you" with Accept and Decline.
class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({super.key, required this.call, this.caller});

  final CallInfo call;

  /// The caller's profile when it is already known (otherwise it is loaded).
  final AppUser? caller;

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  final _service = CallService.instance;
  final _tone = CallTone(incoming: true);
  StreamSubscription<CallInfo?>? _watch;
  AppUser? _caller;
  bool _answered = false;

  @override
  void initState() {
    super.initState();
    _caller = widget.caller;
    unawaited(_tone.start());
    // the caller gave up (or it timed out): close
    _watch = _service.watch(widget.call.id).listen((c) {
      if (!_answered && (c == null || c.status != CallStatus.ringing)) _close();
    });
    if (_caller == null) {
      UserService.instance
          .getUser(widget.call.callerId)
          .then((u) {
            if (mounted) setState(() => _caller = u);
          })
          .catchError((Object _) => null);
    }
  }

  void _close() {
    if (mounted) Navigator.of(context).pop();
  }

  void _decline() {
    if (_answered) return;
    _answered = true;
    unawaited(_service.setStatus(widget.call.id, CallStatus.declined));
    _close();
  }

  void _accept() {
    if (_answered) return;
    _answered = true;
    final nav = Navigator.of(context);
    nav.pushReplacement(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => CallScreen(
          peerUid: widget.call.callerId,
          peerName: _caller?.username ?? 'Call',
          peerPhoto: _caller?.photoUrl ?? '',
          video: widget.call.video,
          existing: widget.call,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _watch?.cancel();
    unawaited(_tone.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.call.video;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _decline();
      },
      child: Scaffold(
        backgroundColor: AppTheme.ink,
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1A1440), AppTheme.ink],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                const Spacer(flex: 2),
                UserAvatar(
                  url: _caller?.photoUrl ?? '',
                  name: _caller?.username ?? '',
                  radius: 66,
                  ring: true,
                ),
                const SizedBox(height: 24),
                Text(
                  _caller?.username ?? '...',
                  key: const ValueKey('callerName'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  video ? 'Incoming video call' : 'Incoming voice call',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(flex: 3),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _big(
                      key: 'declineCall',
                      icon: Icons.call_end_rounded,
                      color: AppTheme.coral,
                      label: 'Decline',
                      onTap: _decline,
                    ),
                    _big(
                      key: 'acceptCall',
                      icon: video ? Icons.videocam_rounded : Icons.call_rounded,
                      color: const Color(0xFF2BD66B),
                      label: 'Accept',
                      onTap: _accept,
                    ),
                  ],
                ),
                const SizedBox(height: 48),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _big({
    required String key,
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Material(
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          key: ValueKey(key),
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 76,
            height: 76,
            child: Icon(icon, color: Colors.white, size: 34),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(label, style: const TextStyle(color: Colors.white70)),
    ],
  );
}
