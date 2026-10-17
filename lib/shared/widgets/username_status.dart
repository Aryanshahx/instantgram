import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// v0.0.2: free / taken check for a new username.
enum UsernameState { empty, bad, checking, free, taken, offline }

/// Same rule as the database: 3-30 chars, a-z 0-9 . _
final RegExp kUsernamePattern = RegExp(r'^[a-z0-9._]{3,30}$');

/// v0.0.2: a small line under the username box: "Checking…",
/// "✓ available" or "✗ taken". Checks while you type (after a short
/// pause). [onState] tells the screen the latest answer.
class UsernameStatus extends StatefulWidget {
  const UsernameStatus({
    super.key,
    required this.controller,
    this.check,
    this.onState,
    this.delay = const Duration(milliseconds: 450),
  });

  final TextEditingController controller;

  /// true = free. Default: reads usernames/{name}.
  final Future<bool> Function(String name)? check;
  final ValueChanged<UsernameState>? onState;
  final Duration delay;

  static Future<bool> defaultCheck(String name) async {
    final snap = await FirebaseFirestore.instance
        .collection('usernames')
        .doc(name)
        .get();
    return !snap.exists;
  }

  @override
  State<UsernameStatus> createState() => _UsernameStatusState();
}

class _UsernameStatusState extends State<UsernameStatus> {
  Timer? _timer;
  String _name = '';
  UsernameState _state = UsernameState.empty;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(UsernameStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _set(UsernameState s) {
    if (!mounted) return;
    if (s != _state) setState(() => _state = s);
    widget.onState?.call(s);
  }

  void _changed() {
    final n = widget.controller.text.trim().toLowerCase();
    if (n == _name) return;
    _name = n;
    _timer?.cancel();
    if (n.isEmpty) return _set(UsernameState.empty);
    if (!kUsernamePattern.hasMatch(n)) return _set(UsernameState.bad);
    _set(UsernameState.checking);
    _timer = Timer(widget.delay, () => _run(n));
  }

  Future<void> _run(String n) async {
    bool free;
    try {
      free = await (widget.check ?? UsernameStatus.defaultCheck)(n);
    } catch (_) {
      if (n == _name) _set(UsernameState.offline);
      return;
    }
    if (n != _name) return; // typed more meanwhile
    _set(free ? UsernameState.free : UsernameState.taken);
  }

  @override
  Widget build(BuildContext context) {
    final (IconData? icon, Color color, String text) = switch (_state) {
      UsernameState.empty => (null, AppColors.textHint, ''),
      UsernameState.bad => (
        Icons.info_outline,
        AppColors.textSecondary,
        '3-30 chars: letters, numbers, . and _',
      ),
      UsernameState.checking => (null, AppColors.textSecondary, 'Checking…'),
      UsernameState.free => (
        Icons.check_circle,
        AppColors.lime,
        '@$_name is available',
      ),
      UsernameState.taken => (
        Icons.cancel,
        AppColors.like,
        '@$_name is taken',
      ),
      UsernameState.offline => (
        Icons.wifi_off,
        AppColors.textSecondary,
        'Could not check now',
      ),
    };
    if (text.isEmpty) return const SizedBox(height: 4);
    return Padding(
      key: ValueKey('username-status-${_state.name}'),
      padding: const EdgeInsets.fromLTRB(14, 5, 8, 0),
      child: Row(
        children: [
          if (_state == UsernameState.checking)
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: AppColors.textSecondary,
              ),
            )
          else if (icon != null)
            Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
