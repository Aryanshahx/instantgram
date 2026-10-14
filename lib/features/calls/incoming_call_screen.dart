import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../shared/widgets/avatar.dart';
import 'call_session.dart';

/// v0.11: incoming call from someone whose calls you muted: no ringing,
/// no vibration, just this screen (while the app is open) and a quiet
/// notification (when it is closed).
class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({
    super.key,
    required this.callId,
    required this.peer,
    required this.video,
    required this.onAccept,
    required this.onDecline,
    this.status,
  });

  final String callId;
  final CallPeer peer;
  final bool video;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  /// Tests: calls/{id}.status.
  final Stream<String?>? status;

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  StreamSubscription<String?>? _sub;
  Timer? _timeout;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    final s =
        widget.status ??
        FirebaseFirestore.instance
            .collection('calls')
            .doc(widget.callId)
            .snapshots()
            .map((d) => d.data()?['status'] as String?);
    _sub = s.listen((st) {
      if (st != CallStatus.ringing) _close(); // hung up / answered elsewhere
    }, onError: (_) {});
    _timeout = Timer(CallSession.ringFor + const Duration(seconds: 5), _close);
  }

  void _close() {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.peer.name.isEmpty ? 'InstantGram user' : widget.peer.name;
    return Scaffold(
      backgroundColor: const Color(0xFF0F1115),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            Avatar(
              url: widget.peer.photoUrl,
              name: name,
              size: 104,
              uid: widget.peer.uid,
            ),
            const SizedBox(height: 18),
            Text(
              name,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.notifications_off_outlined,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  widget.video ? 'Muted video call' : 'Muted voice call',
                  key: const ValueKey('incoming-label'),
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
            const Spacer(flex: 3),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _Round(
                  key: const ValueKey('incoming-decline'),
                  color: const Color(0xFFE5484D),
                  icon: Icons.call_end_rounded,
                  label: 'Decline',
                  onTap: () {
                    if (_done) return;
                    _done = true;
                    widget.onDecline();
                    Navigator.of(context).maybePop();
                  },
                ),
                _Round(
                  key: const ValueKey('incoming-accept'),
                  color: const Color(0xFF3DDC84),
                  icon: widget.video ? Icons.videocam_rounded : Icons.call_rounded,
                  label: 'Accept',
                  onTap: () {
                    if (_done) return;
                    _done = true;
                    widget.onAccept();
                  },
                ),
              ],
            ),
            const SizedBox(height: 56),
          ],
        ),
      ),
    );
  }
}

class _Round extends StatelessWidget {
  const _Round({
    super.key,
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 34),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}
