import 'package:flutter/material.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/push_service.dart';
import 'settings_widgets.dart';

/// Settings > Notifications: push notifications on this account's phones on or off.
/// Muting one chat stays in the chat's long-press menu.
class PushSettingsScreen extends StatefulWidget {
  const PushSettingsScreen({super.key});

  @override
  State<PushSettingsScreen> createState() => _PushSettingsScreenState();
}

class _PushSettingsScreenState extends State<PushSettingsScreen> {
  bool _on = true;
  bool _loaded = false;
  bool _testing = false;
  String? _result;
  bool _resultOk = false;

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    final r = await PushService.instance.sendTest();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = r.detail;
      _resultOk = r.ok;
    });
  }

  @override
  void initState() {
    super.initState();
    PushService.instance.isOff().then((off) {
      if (!mounted) return;
      setState(() {
        _on = !off;
        _loaded = true;
      });
    });
  }

  Future<void> _set(bool on) async {
    setState(() => _on = on);
    try {
      await PushService.instance.setOff(!on);
    } catch (_) {
      if (!mounted) return;
      setState(() => _on = !on);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save. Try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: context.tr('Notifications'),
      children: [
        SwitchListTile(
          key: const ValueKey('pushSwitch'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          title: Text(
            context.tr('Push notifications'),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: const Text(
            'Messages, calls, likes, comments and follows on your phone when InstantGram is closed',
          ),
          value: _on,
          onChanged: _loaded ? _set : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Text(
            'To silence one chat, long-press it in Chats and choose Mute messages or Mute calls.',
            style: TextStyle(color: context.muted),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('pushTest'),
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.notifications_active_outlined),
              label: const Text('Send me a test notification'),
            ),
          ),
        ),
        if (_result != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Text(
              _result!,
              key: const ValueKey('pushTestResult'),
              style: TextStyle(
                color: _resultOk ? AppTheme.volt : Colors.redAccent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}
