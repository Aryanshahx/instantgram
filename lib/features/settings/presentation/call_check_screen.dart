import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/services/calls.dart';
import '../../../core/services/system_settings.dart';
import '../../../core/theme/app_colors.dart';
import 'settings_widgets.dart';

/// v0.11 Settings -> Calls & notifications: checks everything a phone
/// needs to ring when the app is closed, with a button to fix each one.
class CallCheckScreen extends StatefulWidget {
  const CallCheckScreen({super.key, this.check, this.maker});

  /// Tests.
  final Future<CallCheck> Function()? check;
  final String? maker;

  @override
  State<CallCheckScreen> createState() => _CallCheckScreenState();
}

class _CallCheckScreenState extends State<CallCheckScreen> {
  CallCheck? _c;
  String _maker = '';
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    // back from Android settings: check again
    _life = AppLifecycleListener(onResume: _load);
    _load();
    if (widget.maker != null) {
      _maker = widget.maker!;
    } else {
      SystemSettings.maker().then((m) {
        if (mounted) setState(() => _maker = m);
      });
    }
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final c = await (widget.check ?? Calls.instance.check)();
    if (mounted) setState(() => _c = c);
  }

  bool get _chinaRom => const [
    'oppo',
    'realme',
    'oneplus',
    'vivo',
    'iqoo',
    'xiaomi',
    'redmi',
    'poco',
  ].any(_maker.contains);

  Widget _row({
    required String id,
    required bool ok,
    required IconData icon,
    required String title,
    required String okText,
    required String badText,
    VoidCallback? fix,
  }) {
    return SettingsTile(
      key: ValueKey('check-$id'),
      icon: icon,
      title: title,
      subtitle: ok ? okText : badText,
      onTap: ok ? null : fix,
      trailing: ok
          ? const Icon(Icons.check_circle, color: Color(0xFF3DDC84), size: 22)
          : TextButton(
              key: ValueKey('fix-$id'),
              onPressed: fix,
              child: const Text(
                'Fix',
                style: TextStyle(
                  color: AppColors.lime,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return SettingsPage(
      title: 'Calls & notifications',
      children: [
        if (c == null)
          const Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
            child: Row(
              children: [
                Icon(
                  c.allGood ? Icons.verified_rounded : Icons.error_outline,
                  color: c.allGood ? const Color(0xFF3DDC84) : AppColors.lime,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    c.allGood
                        ? 'This phone is ready to ring.'
                        : 'Fix the items below so calls ring when the app '
                              'is closed.',
                    key: const ValueKey('check-summary'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
          SettingsCard(
            children: [
              _row(
                id: 'notifications',
                ok: c.notifications,
                icon: Icons.notifications_outlined,
                title: 'Notifications',
                okText: 'Allowed',
                badText: 'Off: no ringing, no message notifications',
                fix: () =>
                    Calls.instance.fixNotifications().then((_) => _load()),
              ),
              _row(
                id: 'fullscreen',
                ok: c.fullScreen,
                icon: Icons.fullscreen_rounded,
                title: 'Calls on the lock screen',
                okText: 'Allowed',
                badText: 'Off: calls only show as a small notification',
                fix: () => Calls.instance.fixFullScreen(),
              ),
              _row(
                id: 'battery',
                ok: c.battery,
                icon: Icons.battery_charging_full_rounded,
                title: 'No battery limits',
                okText: 'The phone will not stop the app',
                badText: 'The phone may block calls when the app is closed',
                fix: () => Calls.instance.fixBattery().then((_) => _load()),
              ),
              _row(
                id: 'registered',
                ok: c.registered,
                icon: Icons.phone_android_rounded,
                title: 'This phone is saved for calls',
                okText: 'Our server can reach it',
                badText: 'Not yet: allow notifications and open the app again',
                fix: _load,
              ),
            ],
          ),
          if (_chinaRom) ...[
            const SettingsHeader('Your phone needs one more step'),
            SettingsCard(
              children: [
                SettingsTile(
                  key: const ValueKey('check-autostart'),
                  icon: Icons.rocket_launch_outlined,
                  title: 'Auto launch / background',
                  subtitle: _makerTip(),
                  onTap: SystemSettings.app,
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }

  String _makerTip() {
    if (_maker.contains('vivo') || _maker.contains('iqoo')) {
      return 'Tap here → Battery → "Allow background activity" (High '
          'background power). Also turn on "Autostart".';
    }
    if (_maker.contains('xiaomi') ||
        _maker.contains('redmi') ||
        _maker.contains('poco')) {
      return 'Tap here → turn on "Autostart" → Battery saver → "No restrictions".';
    }
    return 'Tap here → Battery usage → turn on "Allow background activity" '
        'and "Auto launch" (or "Allow auto launch").';
  }
}
