import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/services/calls.dart';
import '../../../core/theme/app_colors.dart';
import '../../settings/presentation/settings_screen.dart'
    show signOutEverything;

/// v0.17: every user must allow notifications and calls on the lock
/// screen. Until both are on, this page is shown instead of the app.
/// Checked at every start and every time the app comes back.
class PermissionGate extends StatefulWidget {
  const PermissionGate({super.key, required this.child});

  final Widget child;

  /// Tests.
  static Future<({bool notifications, bool lockScreen})> Function()? debugCheck;
  static Future<void> Function()? debugAskNotifications;
  static Future<void> Function()? debugAskLockScreen;

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate> {
  ({bool notifications, bool lockScreen})? _st;
  late final AppLifecycleListener _life;
  bool _busy = false;

  bool get _ok => _st != null && _st!.notifications && _st!.lockScreen;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(onResume: _check);
    _check();
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final f = PermissionGate.debugCheck ?? Calls.instance.mustHave;
    final st = await f();
    if (mounted) setState(() => _st = st);
  }

  Future<void> _ask(Future<void> Function() ask) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ask();
    } catch (_) {}
    await _check();
    if (mounted) setState(() => _busy = false);
  }

  Widget _row({
    required String id,
    required bool done,
    required IconData icon,
    required String title,
    required String text,
    required Future<void> Function() ask,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: done ? AppColors.lime : AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.lime, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15.5,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  text,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          done
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(
                    Icons.check_circle,
                    key: ValueKey('perm-ok'),
                    color: AppColors.lime,
                  ),
                )
              : FilledButton(
                  key: ValueKey('perm-allow-$id'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.lime,
                    foregroundColor: Colors.black,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _busy ? null : () => _ask(ask),
                  child: const Text(
                    'Allow',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final st = _st;
    if (st == null) {
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_ok) return widget.child;
    return Scaffold(
      key: const ValueKey('permission-gate'),
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 40, 20, 24),
          children: [
            const Icon(
              Icons.notifications_active_rounded,
              size: 56,
              color: AppColors.lime,
            ),
            const SizedBox(height: 16),
            const Text(
              'Allow to continue',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              'InstantGram needs these so messages and calls reach you, '
              'even when your phone is locked.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 28),
            _row(
              id: 'notifications',
              done: st.notifications,
              icon: Icons.notifications_outlined,
              title: 'Notifications',
              text: 'Messages, calls, likes and comments.',
              ask:
                  PermissionGate.debugAskNotifications ??
                  Calls.instance.fixNotifications,
            ),
            _row(
              id: 'lockscreen',
              done: st.lockScreen,
              icon: Icons.phone_locked_outlined,
              title: 'Calls on the lock screen',
              text:
                  'Calls ring full screen when the phone is locked. '
                  'Turn on "InstantGram" on the next page.',
              ask:
                  PermissionGate.debugAskLockScreen ??
                  Calls.instance.fixFullScreen,
            ),
            const SizedBox(height: 18),
            Center(
              child: TextButton(
                key: const ValueKey('perm-logout'),
                onPressed: () => unawaited(signOutEverything()),
                child: const Text(
                  'Log out',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
