import 'package:flutter/material.dart';

import '../../../core/services/chat_prefs.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import 'call_check_screen.dart';
import 'settings_widgets.dart';

/// v0.12: Settings -> Notifications. Which phone notifications you get
/// (likes, comments, followers, views ...). Saved in prefs/{uid}.pushOff,
/// so it works on every phone where you are logged in.
class NotificationSettingsScreen extends StatelessWidget {
  const NotificationSettingsScreen({super.key, this.onChanged});

  /// Tests (default: saves in Firestore).
  final Future<void> Function(String kind, bool on)? onChanged;

  Future<void> _set(BuildContext context, String kind, bool on) async {
    try {
      await (onChanged ?? ChatPrefs.instance.setPush)(kind, on);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ChatPrefsData>(
      valueListenable: ChatPrefs.instance.value,
      builder: (context, prefs, _) => SettingsPage(
        title: 'Notifications',
        children: [
          const SettingsHeader('Push notifications'),
          SettingsCard(
            children: [
              for (final (kind, title, subtitle) in PushKinds.all)
                SettingsSwitch(
                  key: ValueKey('push-$kind'),
                  icon: _icon(kind),
                  title: title,
                  subtitle: subtitle,
                  value: prefs.pushOn(kind),
                  onChanged: (v) => _set(context, kind, v),
                ),
            ],
          ),
          const SettingsHeader('Messages and calls'),
          SettingsCard(
            children: [
              SettingsTile(
                icon: Icons.ring_volume_outlined,
                title: 'Calls & notifications check',
                subtitle: 'Test ringing when the app is closed',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const CallCheckScreen(),
                  ),
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 10, 8, 0),
            child: Text(
              'To mute one chat or one person\'s calls, long-press the chat '
              'in Chats.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  static IconData _icon(String kind) => switch (kind) {
    PushKinds.likes => Icons.favorite_border,
    PushKinds.comments => Icons.mode_comment_outlined,
    PushKinds.commentLikes => Icons.thumb_up_alt_outlined,
    PushKinds.follows => Icons.person_add_alt_1_outlined,
    PushKinds.unfollows => Icons.person_remove_alt_1_outlined,
    PushKinds.reposts => Icons.repeat,
    PushKinds.views => Icons.bar_chart_rounded,
    _ => Icons.notifications_none,
  };
}
