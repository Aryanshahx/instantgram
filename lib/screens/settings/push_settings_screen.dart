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
      ],
    );
  }
}
