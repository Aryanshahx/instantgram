import 'package:flutter/material.dart';

import '../../../core/services/saved_accounts.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/widgets/avatar.dart';
import '../../auth/data/auth_service.dart';
import 'settings_screen.dart' show signOutEverything;
import 'settings_widgets.dart';

/// v0.12: Settings -> Accounts. Switch between accounts saved on this
/// phone, add another account, or remove one.
class AccountsScreen extends StatefulWidget {
  const AccountsScreen({
    super.key,
    required this.profile,
    this.onSwitch,
    this.onAdd,
  });

  final UserProfile profile;

  /// Tests (default: [switchToAccount] / [addAccount]).
  final Future<void> Function(SavedAccount a)? onSwitch;
  final Future<void> Function()? onAdd;

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  final _store = SavedAccounts.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _store.load().then((_) => _store.updateProfile(widget.profile));
  }

  Future<void> _run(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(SavedAccount a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Remove ${a.label}?'),
        content: const Text(
          'It is removed from this phone only. The account itself is not '
          'deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Remove', style: TextStyle(color: AppColors.like)),
          ),
        ],
      ),
    );
    if (ok == true) await _store.remove(a.uid);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<SavedAccount>>(
      valueListenable: _store.accounts,
      builder: (context, list, _) {
        final me = widget.profile;
        final others = list.where((a) => a.uid != me.uid).toList();
        return SettingsPage(
          title: 'Accounts',
          children: [
            const SettingsHeader('Logged in now'),
            SettingsCard(
              children: [
                ListTile(
                  key: const ValueKey('account-current'),
                  dense: true,
                  leading: Avatar(url: me.photoUrl, name: me.username, size: 38),
                  title: Text(
                    '@${me.username}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    me.email,
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                  trailing: const Icon(
                    Icons.check_circle,
                    color: AppColors.lime,
                    size: 22,
                  ),
                ),
              ],
            ),
            if (others.isNotEmpty) ...[
              const SettingsHeader('Switch to'),
              SettingsCard(
                children: [
                  for (final a in others)
                    ListTile(
                      key: ValueKey('account-${a.uid}'),
                      dense: true,
                      enabled: !_busy,
                      leading: Avatar(url: a.photoUrl, name: a.username, size: 38),
                      title: Text(
                        a.label,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        a.email,
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                      onTap: () => _run(
                        () => (widget.onSwitch ??
                            (x) => switchToAccount(context, x))(a),
                      ),
                      trailing: PopupMenuButton<String>(
                        key: ValueKey('account-menu-${a.uid}'),
                        icon: const Icon(Icons.more_vert, size: 20),
                        onSelected: (v) {
                          if (v == 'remove') _remove(a);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'remove',
                            child: Text('Remove from this phone'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            SettingsCard(
              children: [
                SettingsTile(
                  key: const ValueKey('account-add'),
                  icon: Icons.person_add_alt_1_outlined,
                  title: 'Add account',
                  subtitle: 'Log in to another account or create a new one',
                  onTap: () => _run(widget.onAdd ?? () => addAccount(context)),
                ),
              ],
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.lime),
                ),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 12, 8, 0),
              child: Text(
                'Accounts and passwords for switching are saved only on this '
                'phone. Remove an account to forget it.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Asks for the password of [a] (wrong / not saved yet). null = cancel.
Future<String?> askAccountPassword(
  BuildContext context,
  SavedAccount a, {
  String? error,
}) async {
  final ctrl = TextEditingController();
  final pw = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text('Password for ${a.label}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(error, style: const TextStyle(color: AppColors.like)),
            ),
          TextField(
            key: const ValueKey('account-password'),
            controller: ctrl,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Password'),
            onSubmitted: (v) => Navigator.pop(d, v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(d, ctrl.text),
          child: const Text('Log in', style: TextStyle(color: AppColors.lime)),
        ),
      ],
    ),
  );
  ctrl.dispose();
  return (pw == null || pw.isEmpty) ? null : pw;
}

/// Switch: check the password first (you stay logged in if it is wrong),
/// then log out and log in to [a].
Future<void> switchToAccount(BuildContext context, SavedAccount a) async {
  final store = SavedAccounts.instance;
  var pw = await store.password(a.uid);
  String? error;
  while (true) {
    if (pw == null) {
      if (!context.mounted) return;
      pw = await askAccountPassword(context, a, error: error);
      if (pw == null) return;
    }
    error = await AuthService.instance.checkPassword(a.email, pw);
    if (error == null) break;
    await store.forgetPassword(a.uid);
    pw = null;
  }
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  Navigator.of(context).popUntil((r) => r.isFirst);
  await signOutEverything();
  try {
    await AuthService.instance.signIn(identifier: a.email, password: pw);
  } on AuthFailure catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

/// Add account: go to the login screen; this account stays saved.
Future<void> addAccount(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Add account'),
      content: const Text(
        'You will go to the login screen. Log in or create the other '
        'account. This account stays saved, so you can switch back in '
        'Settings -> Accounts.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(d, true),
          child: const Text('Continue', style: TextStyle(color: AppColors.lime)),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  Navigator.of(context).popUntil((r) => r.isFirst);
  await signOutEverything();
}
