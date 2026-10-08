import 'package:flutter/material.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../core/legal.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../services/app_prefs.dart';
import '../../services/auth_service.dart';
import '../../services/safety_service.dart';
import '../profile/edit_profile_screen.dart';
import '../profile/saved_posts_screen.dart';
import 'account_screens.dart';
import 'activity_screens.dart';
import 'app_screens.dart';
import 'delete_account_screen.dart';
import 'settings_widgets.dart';

class _Item {
  const _Item(this.id, this.icon, this.title, this.keywords, this.open);
  final String id;
  final IconData icon;

  /// English title (translated when shown).
  final String title;

  /// Extra words that also find this row.
  final String keywords;
  final void Function(BuildContext context, AppUser? me) open;
}

/// Settings: a search bar and every setting in groups.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.me});

  /// My profile (for Edit profile).
  final AppUser? me;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _search = TextEditingController();

  static final _groups = <(String, List<_Item>)>[
    (
      'Your activity',
      [
        _Item(
          'saved',
          Icons.bookmark_border_rounded,
          'Saved',
          'bookmarks saved posts',
          (c, _) => openScreen(c, const SavedPostsScreen()),
        ),
        _Item(
          'history',
          Icons.history_rounded,
          'History',
          'watched viewed recently clear',
          (c, _) => openScreen(c, const HistoryScreen()),
        ),
        _Item(
          'time',
          Icons.timer_outlined,
          'Manage time',
          'screen time usage limit daily reminder',
          (c, _) => openScreen(c, const ManageTimeScreen()),
        ),
      ],
    ),
    (
      'Account',
      [
        _Item(
          'edit',
          Icons.edit_outlined,
          'Edit profile',
          'name bio photo username links',
          (c, me) {
            if (me != null) openScreen(c, EditProfileScreen(user: me));
          },
        ),
        _Item(
          'add',
          Icons.person_add_alt_1_outlined,
          'Add account',
          'switch another login',
          (c, _) => openScreen(c, const AddAccountScreen()),
        ),
        _Item(
          'privacy',
          Icons.lock_outline_rounded,
          'Account privacy',
          'private requests followers hide',
          (c, _) => openScreen(c, const AccountPrivacyScreen()),
        ),
        _Item(
          'blocked',
          Icons.block_rounded,
          'Blocked',
          'block unblock people',
          (c, _) => openScreen(c, const BlockedScreen()),
        ),
        _Item(
          'delete',
          Icons.delete_forever_rounded,
          'Delete account',
          'request removal erase content data',
          (c, _) => openScreen(c, const DeleteAccountScreen()),
        ),
      ],
    ),
    (
      'App',
      [
        _Item(
          'access',
          Icons.accessibility_new_rounded,
          'Accessibility',
          'text size bold motion dark light theme',
          (c, _) => openScreen(c, const AccessibilityScreen()),
        ),
        _Item(
          'language',
          Icons.language_rounded,
          'Language',
          'hindi english spanish french',
          (c, _) => openScreen(c, const LanguageScreen()),
        ),
        _Item(
          'update',
          Icons.system_update_rounded,
          'App update',
          'version new download',
          (c, _) => openScreen(c, const AppUpdateScreen()),
        ),
      ],
    ),
    (
      'Help and about',
      [
        _Item(
          'about',
          Icons.info_outline_rounded,
          'About',
          'version contact help support',
          (c, _) => openScreen(c, const AboutScreen()),
        ),
        _Item(
          'policy',
          Icons.privacy_tip_outlined,
          'Privacy policy',
          'data privacy',
          (c, _) => openLegal(
            c,
            kPrivacyUrl,
            () => openScreen(c, const PrivacyPolicyScreen()),
          ),
        ),
        _Item(
          'terms',
          Icons.gavel_rounded,
          'Terms of use',
          'rules terms conditions',
          (c, _) => openLegal(
            c,
            kTermsUrl,
            () => openScreen(c, const TermsScreen()),
          ),
        ),
      ],
    ),
  ];

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _logout() async {
    final ok = await confirm(
      context,
      title: 'Log out?',
      confirmLabel: context.tr('Log out'),
      destructive: true,
    );
    if (!ok || !mounted) return;
    final u = AuthService.instance.currentUser;
    if (u != null && u.displayName != null) {
      AppPrefs.instance.rememberAccount(
        SavedAccount(
          uid: u.uid,
          username: widget.me?.username ?? u.displayName ?? '',
          photoUrl: widget.me?.photoUrl ?? '',
          email: u.email ?? '',
        ),
      );
    }
    SafetyService.instance.clear();
    Navigator.of(context).popUntil((r) => r.isFirst);
    await AuthService.instance.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    bool match(_Item i) =>
        q.isEmpty ||
        context.tr(i.title).toLowerCase().contains(q) ||
        i.title.toLowerCase().contains(q) ||
        i.keywords.contains(q);

    final rows = <Widget>[];
    for (final g in _groups) {
      final items = g.$2.where(match).toList();
      if (items.isEmpty) continue;
      rows.add(SettingsHeading(context.tr(g.$1)));
      for (final i in items) {
        rows.add(
          SettingsTile(
            key: ValueKey('setting_${i.id}'),
            icon: i.icon,
            title: context.tr(i.title),
            onTap: () => i.open(context, widget.me),
          ),
        );
      }
    }
    final logoutMatches =
        q.isEmpty ||
        context.tr('Log out').toLowerCase().contains(q) ||
        'log out sign out logout'.contains(q);
    if (logoutMatches) {
      rows.add(const SizedBox(height: 12));
      rows.add(
        SettingsTile(
          key: const ValueKey('setting_logout'),
          icon: Icons.logout_rounded,
          title: context.tr('Log out'),
          destructive: true,
          onTap: _logout,
        ),
      );
    }
    if (rows.isEmpty) {
      rows.add(
        Padding(
          padding: const EdgeInsets.all(40),
          child: Center(
            child: Text(
              'No setting matches "$q".',
              style: TextStyle(color: context.muted),
            ),
          ),
        ),
      );
    }
    return SettingsPage(
      title: context.tr('Settings'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            key: const ValueKey('settingsSearch'),
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: context.tr('Search settings'),
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: q.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => setState(_search.clear),
                    ),
            ),
          ),
        ),
        ...rows,
      ],
    );
  }
}
