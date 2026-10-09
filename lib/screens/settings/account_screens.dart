import 'package:flutter/material.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../services/account_vault.dart';
import '../../services/app_prefs.dart';
import '../../services/auth_service.dart';
import '../../services/safety_service.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/state_views.dart';
import '../auth/login_screen.dart';
import '../profile/profile_screen.dart';
import 'settings_widgets.dart';

/// Settings > Add account: the accounts this phone knows, switch to one or log in to another.
class AddAccountScreen extends StatefulWidget {
  const AddAccountScreen({super.key});

  @override
  State<AddAccountScreen> createState() => _AddAccountScreenState();
}

class _AddAccountScreenState extends State<AddAccountScreen> {
  /// Accounts whose login is saved on this phone (switch without a password).
  Set<String> _ready = const {};
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    AccountVault.instance.uids().then((v) {
      if (mounted) setState(() => _ready = v);
    });
  }

  Future<void> _switch(BuildContext context, SavedAccount a) async {
    if (!_ready.contains(a.uid)) {
      await _goToLogin(
        context,
        prefill: a.username,
        message: 'Switch to @${a.username}?',
      );
      return;
    }
    setState(() => _switching = true);
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.isFirst);
    SafetyService.instance.clear();
    final ok = await AuthService.instance.switchTo(a.uid);
    if (!ok) LoginScreen.prefill = a.username;
    if (mounted) setState(() => _switching = false);
  }

  Future<void> _goToLogin(
    BuildContext context, {
    String prefill = '',
    required String message,
  }) async {
    final ok = await confirm(
      context,
      title: message,
      message:
          'Your account stays saved on this phone. You will log in with the other account and can come back any time.',
      confirmLabel: 'Continue',
    );
    if (!ok || !context.mounted) return;
    LoginScreen.prefill = prefill;
    Navigator.of(context).popUntil((r) => r.isFirst);
    await AuthService.instance.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final me = AuthService.instance.currentUser?.uid ?? '';
    final others = [
      for (final a in AppPrefs.instance.accounts)
        if (a.uid != me) a,
    ];
    return SettingsPage(
      title: context.tr('Add account'),
      children: [
        SettingsTile(
          key: const ValueKey('addAccountButton'),
          icon: Icons.person_add_alt_1_rounded,
          title: context.tr('Add account'),
          subtitle: 'Log in to another account',
          onTap: () => _goToLogin(context, message: 'Add another account?'),
        ),
        if (others.isNotEmpty) SettingsHeading(context.tr('Switch account')),
        for (final a in others)
          ListTile(
            key: ValueKey('saved_${a.uid}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: UserAvatar(
              url: a.photoUrl,
              name: a.username,
              radius: 22,
              uid: a.uid,
            ),
            title: Text(
              a.username,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text(
              _ready.contains(a.uid) ? 'Tap to switch' : 'Tap to log in',
            ),
            trailing: IconButton(
              tooltip: 'Forget',
              icon: const Icon(Icons.close_rounded),
              onPressed: () async {
                AppPrefs.instance.forgetAccount(a.uid);
                await AccountVault.instance.forget(a.uid);
                if (mounted) setState(() {});
              },
            ),
            onTap: _switching ? null : () => _switch(context, a),
          ),
      ],
    );
  }
}

/// Settings > Account privacy.
class AccountPrivacyScreen extends StatefulWidget {
  const AccountPrivacyScreen({super.key});

  @override
  State<AccountPrivacyScreen> createState() => _AccountPrivacyScreenState();
}

class _AccountPrivacyScreenState extends State<AccountPrivacyScreen> {
  bool? _private;
  bool _busy = false;
  List<PersonRef>? _requests;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final me = await UserService.instance.getUser(UserService.instance.myUid);
      final reqs = await SafetyService.instance.incomingRequests();
      if (!mounted) return;
      setState(() {
        _private = me?.isPrivate ?? false;
        _requests = reqs;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _toggle(bool v) async {
    setState(() {
      _busy = true;
      _private = v;
    });
    try {
      await SafetyService.instance.setPrivate(v);
    } catch (e) {
      if (mounted) {
        setState(() => _private = !v);
        showToast(context, friendlyError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _answer(PersonRef p, bool accept) async {
    try {
      if (accept) {
        await SafetyService.instance.accept(p.uid);
      } else {
        await SafetyService.instance.decline(p.uid);
      }
      if (mounted) setState(() => _requests = [..._requests!]..remove(p));
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(context.tr('Account privacy'))),
        body: ErrorState(error: _error!, onRetry: _load),
      );
    }
    final reqs = _requests ?? const <PersonRef>[];
    return SettingsPage(
      title: context.tr('Account privacy'),
      children: [
        SwitchListTile(
          key: const ValueKey('privateSwitch'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          secondary: const Icon(Icons.lock_outline_rounded),
          title: Text(
            context.tr('Private account'),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            context.tr('Only people you approve can see your posts and clips.'),
          ),
          value: _private ?? false,
          onChanged: (_private == null || _busy) ? null : _toggle,
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Text(
            'When it is on, new people must send a request. You accept it below, and they start following you the next time they open the app. Your older posts are updated too (the newest 400).',
            style: TextStyle(fontSize: 13, height: 1.4),
          ),
        ),
        SettingsHeading(context.tr('Follow requests')),
        if (_requests == null)
          const Padding(padding: EdgeInsets.all(24), child: CenteredLoader())
        else if (reqs.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Text(
              context.tr('Nothing here yet.'),
              style: TextStyle(color: context.muted),
            ),
          ),
        for (final p in reqs)
          ListTile(
            key: ValueKey('req_${p.uid}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: UserAvatar(url: p.photoUrl, name: p.username, radius: 22),
            title: Text(
              p.username,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            onTap: () => openScreen(context, ProfileScreen(uid: p.uid)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  onPressed: () => _answer(p, true),
                  child: Text(context.tr('Accept')),
                ),
                const SizedBox(width: 6),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onPressed: () => _answer(p, false),
                  child: Text(context.tr('Decline')),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        SettingsTile(
          icon: Icons.block_rounded,
          title: context.tr('Blocked'),
          onTap: () => openScreen(context, const BlockedScreen()),
        ),
      ],
    );
  }
}

/// Settings > Blocked.
class BlockedScreen extends StatefulWidget {
  const BlockedScreen({super.key});

  @override
  State<BlockedScreen> createState() => _BlockedScreenState();
}

class _BlockedScreenState extends State<BlockedScreen> {
  List<PersonRef>? _people;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await SafetyService.instance.blockedPeople();
      if (mounted) {
        setState(() {
          _people = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _unblock(PersonRef p) async {
    try {
      await SafetyService.instance.unblock(p.uid);
      if (mounted) setState(() => _people = [..._people!]..remove(p));
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _people;
    return SettingsPage(
      title: context.tr('Blocked'),
      children: [
        if (_error != null)
          ErrorState(error: _error!, onRetry: _load)
        else if (list == null)
          const Padding(padding: EdgeInsets.all(40), child: CenteredLoader())
        else if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.all(40),
            child: Center(
              child: Text(
                context.tr('Nobody is blocked.'),
                style: TextStyle(color: context.muted),
              ),
            ),
          ),
        for (final p in list ?? const <PersonRef>[])
          ListTile(
            key: ValueKey('blocked_${p.uid}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: UserAvatar(url: p.photoUrl, name: p.username, radius: 22),
            title: Text(
              p.username,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            trailing: OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              onPressed: () => _unblock(p),
              child: Text(context.tr('Unblock')),
            ),
          ),
      ],
    );
  }
}

/// Block / unblock sheet used from profiles.
Future<void> toggleBlock(BuildContext context, AppUser user) async {
  final blocked = SafetyService.instance.isBlocked(user.uid);
  final ok = await confirm(
    context,
    title: blocked ? 'Unblock @${user.username}?' : 'Block @${user.username}?',
    message: blocked
        ? 'Their posts and clips will show again.'
        : 'You will no longer see their posts and clips, and you stop following them.',
    confirmLabel: blocked ? 'Unblock' : 'Block',
    destructive: !blocked,
  );
  if (!ok || !context.mounted) return;
  try {
    if (blocked) {
      await SafetyService.instance.unblock(user.uid);
    } else {
      await SafetyService.instance.block(
        PersonRef(
          uid: user.uid,
          username: user.username,
          photoUrl: user.photoUrl,
        ),
      );
    }
    if (context.mounted) {
      showToast(
        context,
        blocked ? 'Unblocked @${user.username}' : 'Blocked @${user.username}',
      );
    }
  } catch (e) {
    if (context.mounted) showToast(context, friendlyError(e));
  }
}
