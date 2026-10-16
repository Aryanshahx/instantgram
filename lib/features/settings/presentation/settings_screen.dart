import 'package:flutter/material.dart';

import '../../../core/config/app_info.dart';
import '../../../core/constants/languages.dart';
import '../../../core/services/app_settings.dart';
import '../../../core/services/calls.dart';
import '../../../core/services/chat_prefs.dart';
import '../../../core/services/presence.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/email.dart';
import '../../../shared/models/user_profile.dart';
import '../../auth/data/auth_service.dart';
import '../../chats/data/chat_receipts.dart';
import '../../shell/push_router.dart';
import '../../profile/presentation/saved_screen.dart';
import 'accounts_screen.dart';
import 'app_icon_screen.dart';
import 'call_check_screen.dart';
import 'history_screen.dart';
import 'notification_settings_screen.dart';
import 'privacy_screens.dart';
import 'settings_pages.dart';
import 'settings_widgets.dart';
import 'time_screen.dart';
import '../../../core/services/account_status.dart';

/// One searchable row in Settings.
class _Item {
  const _Item({
    required this.section,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.keywords = '',
    this.danger = false,
  });

  final String section;
  final IconData icon;
  final String title;
  final String? subtitle;
  final String keywords;
  final bool danger;
  final void Function(BuildContext context) onTap;

  bool matches(String q) {
    final hay = '$title ${subtitle ?? ''} $section $keywords'.toLowerCase();
    return q.split(RegExp(r'\s+')).every(hay.contains);
  }
}

/// Me → ⚙ Settings (with search).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.profile});
  final UserProfile profile;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => page))
          .then((_) {
            if (mounted) setState(() {}); // e.g. Activity status On / Off
          });

  List<_Item> _items() {
    final p = widget.profile;
    final lang = languageByCode(
      p.language.isNotEmpty ? p.language : AppSettings.instance.language.value,
    )?.name;
    return [
      _Item(
        section: 'Your account',
        icon: Icons.account_circle_outlined,
        title: 'Account',
        subtitle: 'Profile, email, password, birthday',
        keywords: 'edit profile name email password reset birthday cover photo',
        onTap: (c) => _push(c, AccountScreen(profile: p)),
      ),
      _Item(
        section: 'Your account',
        icon: Icons.bookmark_border,
        title: 'Saved',
        keywords: 'bookmarks saved posts clips',
        onTap: (c) => _push(c, const SavedScreen()),
      ),
      _Item(
        section: 'How you use InstantGram',
        icon: Icons.history,
        title: 'History',
        subtitle: 'Posts and clips you watched',
        keywords: 'watched viewed recently clear',
        onTap: (c) => _push(c, const HistoryScreen()),
      ),
      _Item(
        section: 'How you use InstantGram',
        icon: Icons.hourglass_bottom_rounded,
        title: 'Manage time',
        subtitle: 'Daily time and reminder',
        keywords: 'screen time usage limit reminder break',
        onTap: (c) => _push(c, const TimeScreen()),
      ),
      _Item(
        section: 'Who can see your content',
        icon: Icons.lock_outline,
        title: 'Account privacy',
        subtitle: p.isPrivate ? 'Private' : 'Public',
        keywords: 'private public follow requests followers',
        onTap: (c) => _push(c, const PrivacyScreen()),
      ),
      _Item(
        section: 'Who can see your content',
        icon: Icons.circle_outlined,
        title: 'Activity status',
        subtitle: Presence.instance.show.value ? 'On' : 'Off',
        keywords: 'active now online last seen status hide',
        onTap: (c) => _push(c, const ActivityStatusScreen()),
      ),
      _Item(
        section: 'Who can see your content',
        icon: Icons.block,
        title: 'Blocked',
        subtitle: 'People you blocked',
        keywords: 'block unblock blocked accounts',
        onTap: (c) => _push(c, const BlockedScreen()),
      ),
      _Item(
        section: 'Your app',
        icon: Icons.notifications_none,
        title: 'Notifications',
        subtitle: 'Likes, comments, followers, views',
        keywords:
            'notification push likes comments followers unfollow views '
            'reposts mute',
        onTap: (c) => _push(c, const NotificationSettingsScreen()),
      ),
      _Item(
        section: 'Your app',
        icon: Icons.ring_volume_outlined,
        title: 'Calls & notifications',
        subtitle: 'Check that calls ring when the app is closed',
        keywords: 'call ring ringing notification push battery test closed',
        onTap: (c) => _push(c, const CallCheckScreen()),
      ),
      _Item(
        section: 'Your app',
        icon: Icons.accessibility_new,
        title: 'Accessibility',
        subtitle: 'Text size, reduce motion',
        keywords: 'font text size bigger animation motion',
        onTap: (c) => _push(c, const AccessibilityScreen()),
      ),
      _Item(
        section: 'Your app',
        icon: Icons.apps_rounded,
        title: 'App icon',
        subtitle: 'Change the home screen icon',
        keywords: 'icon logo launcher home screen color theme',
        onTap: (c) => _push(c, const AppIconScreen()),
      ),
      _Item(
        section: 'Your app',
        icon: Icons.translate,
        title: 'Language',
        subtitle: lang ?? 'Not set',
        keywords: 'language hindi english',
        onTap: (c) => _push(c, LanguageScreen(profile: p)),
      ),
      _Item(
        section: 'More info and support',
        icon: Icons.info_outline,
        title: 'About',
        keywords: 'about version contact help support error log crash',
        onTap: (c) => _push(c, const AboutScreen()),
      ),
      _Item(
        section: 'More info and support',
        icon: Icons.privacy_tip_outlined,
        title: 'Privacy policy',
        keywords: 'privacy data policy',
        onTap: (c) => openLink(c, AppInfo.privacyPolicyUrl),
      ),
      _Item(
        section: 'More info and support',
        icon: Icons.description_outlined,
        title: 'Terms of use',
        keywords: 'terms rules conditions',
        onTap: (c) => openLink(c, AppInfo.termsUrl),
      ),
      _Item(
        section: 'Login',
        icon: Icons.switch_account_outlined,
        title: 'Accounts',
        subtitle: 'Add account or switch',
        keywords: 'add account switch accounts multiple second another login',
        onTap: (c) => _push(c, AccountsScreen(profile: p)),
      ),
      _Item(
        section: 'Login',
        icon: Icons.logout,
        title: 'Log out',
        subtitle: '@${p.username}',
        keywords: 'sign out logout exit',
        danger: true,
        onTap: confirmLogout,
      ),
      _Item(
        section: 'Login',
        icon: Icons.delete_forever_outlined,
        title: 'Delete account',
        subtitle: 'Send a deletion request',
        keywords: 'remove delete close account',
        danger: true,
        onTap: (c) => requestAccountDeletion(c, p),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final all = _items();
    final shown = q.isEmpty ? all : all.where((i) => i.matches(q)).toList();

    final children = <Widget>[];
    String? section;
    var group = <Widget>[];
    void flush() {
      if (group.isNotEmpty) {
        children.add(SettingsCard(children: group));
        group = [];
      }
    }

    for (final i in shown) {
      if (i.section != section) {
        flush();
        section = i.section;
        children.add(SettingsHeader(i.section));
      }
      group.add(
        SettingsTile(
          icon: i.icon,
          title: i.title,
          subtitle: i.subtitle,
          danger: i.danger,
          onTap: () => i.onTap(context),
        ),
      );
    }
    flush();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
            child: TextField(
              key: const ValueKey('settings-search'),
              controller: _search,
              onChanged: (v) => setState(() => _q = v),
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                hintText: 'Search settings',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _q.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() {
                          _search.clear();
                          _q = '';
                        }),
                      ),
                isDense: true,
                filled: true,
                fillColor: AppColors.surface,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppColors.lime),
                ),
              ),
            ),
          ),
          if (shown.isEmpty)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(
                child: Text(
                  'No settings found',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
            ),
          ...children,
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Center(
              child: Text(
                'InstantGram ${AppInfo.version} · ${AppInfo.company}',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Log out?" confirm.
Future<void> confirmLogout(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Log out?'),
      content: const Text('You can log back in any time.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(d, true),
          child: const Text('Log out', style: TextStyle(color: AppColors.like)),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  Navigator.of(context).popUntil((r) => r.isFirst);
  await signOutEverything();
}

/// Log out: this phone stops ringing / getting messages for the account.
/// v0.12: also used by Settings -> Accounts (switch / add account).
Future<void> signOutEverything() async {
  await Calls.instance.signOut(); // no calls for this phone any more
  await Presence.instance.stop();
  ChatReceipts.instance.stop();
  ChatPrefs.instance.stop();
  PushRouter.instance.stop();
  AccountStatus.instance.stop();
  await AuthService.instance.signOut();
}

/// Users can't delete accounts themselves: they email a request.
Future<void> requestAccountDeletion(BuildContext context, UserProfile p) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      icon: const Icon(
        Icons.delete_forever_outlined,
        color: AppColors.like,
        size: 34,
      ),
      title: const Text('Delete your account?'),
      content: const Text(
        'Account deletion is done by our team. We will open your email app '
        'with a ready request to ${AppInfo.supportEmail}.\n\n'
        'Send it from the email linked to your account. Your profile, posts, '
        'clips, moments and messages will be removed within 30 days.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(d, true),
          child: const Text(
            'Write email',
            style: TextStyle(color: AppColors.like),
          ),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  await openEmail(
    context,
    to: AppInfo.supportEmail,
    subject: 'Delete my InstantGram account (@${p.username})',
    body: [
      'Hello InstantGram team,',
      '',
      'Please delete my account and all my data.',
      '',
      'Username: @${p.username}',
      'Email: ${p.email}',
      'User ID: ${p.uid}',
      '',
      'Reason (optional): ',
      '',
      'Thank you.',
    ].join('\n'),
  );
}
