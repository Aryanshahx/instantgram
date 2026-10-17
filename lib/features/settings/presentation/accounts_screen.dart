import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/services/account_family.dart';
import '../../../core/services/api_client.dart';
import '../../../core/services/saved_accounts.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/hi_text_check.dart';
import '../../../shared/widgets/username_status.dart';
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
    this.onNewLinked,
  });

  final UserProfile profile;

  /// Tests (default: [createLinkedAccount]).
  final Future<void> Function()? onNewLinked;

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
    // v0.0.2: accounts of this login (for switching without a password)
    unawaited(
      AccountFamily.instance
          .refresh(email: widget.profile.email)
          .then<void>((_) {}, onError: (Object e) => debugPrint('accounts: $e')),
    );
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
            child: const Text(
              'Remove',
              style: TextStyle(color: AppColors.like),
            ),
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
                  leading: Avatar(
                    url: me.photoUrl,
                    name: me.username,
                    size: 38,
                  ),
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
                      leading: Avatar(
                        url: a.photoUrl,
                        name: a.username,
                        size: 38,
                      ),
                      title: Text(
                        a.label,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        a.linked ? 'Same login' : a.email,
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                      onTap: () => _run(
                        () =>
                            (widget.onSwitch ??
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
                // v0.0.2: one email + password, many accounts
                SettingsTile(
                  key: const ValueKey('account-new-linked'),
                  icon: Icons.group_add_outlined,
                  title: 'New account, same login',
                  subtitle: 'Uses your email and password · up to '
                      '${AccountFamily.max} accounts',
                  onTap: () => _run(
                    widget.onNewLinked ??
                        () => createLinkedAccount(context, widget.profile),
                  ),
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
                'phone. Remove an account to forget it. Accounts made with '
                '"same login" open after logging in with your email.',
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
  // v0.0.2: an account of this login: no password needed
  if (a.linked || AccountFamily.instance.contains(a.uid)) {
    final done = await switchFamilyAccount(context, a.uid, quietDenied: true);
    if (done || !context.mounted) return;
    if (a.linked) return _linkedWithPassword(context, a);
  }
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
          child: const Text(
            'Continue',
            style: TextStyle(color: AppColors.lime),
          ),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  Navigator.of(context).popUntil((r) => r.isFirst);
  await signOutEverything();
}

/// v0.14: Me screen -> switch account (a small sheet like Instagram).
Future<void> showAccountSwitcher(
  BuildContext context,
  UserProfile me, {
  Future<void> Function(SavedAccount a)? onSwitch,
  Future<void> Function()? onAdd,
}) async {
  final store = SavedAccounts.instance;
  await store.load();
  await store.updateProfile(me);
  if (!context.mounted) return;
  final picked = await showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.7,
        ),
        child: ValueListenableBuilder<List<SavedAccount>>(
          valueListenable: store.accounts,
          builder: (ctx, list, _) {
            final others = list.where((a) => a.uid != me.uid).toList();
            return ListView(
              shrinkWrap: true,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 6),
                  child: Text(
                    'Switch account',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ),
                ListTile(
                  key: const ValueKey('switch-current'),
                  dense: true,
                  leading: Avatar(
                    url: me.photoUrl,
                    name: me.username,
                    size: 36,
                  ),
                  title: Text(
                    '@${me.username}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  trailing: const Icon(
                    Icons.check_circle,
                    color: AppColors.lime,
                    size: 22,
                  ),
                  onTap: () => Navigator.pop(ctx),
                ),
                for (final a in others)
                  ListTile(
                    key: ValueKey('switch-to-${a.uid}'),
                    dense: true,
                    leading: Avatar(
                      url: a.photoUrl,
                      name: a.username,
                      size: 36,
                    ),
                    title: Text(
                      a.label,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    trailing: const Icon(
                      Icons.radio_button_off,
                      color: AppColors.textSecondary,
                      size: 22,
                    ),
                    onTap: () => Navigator.pop(ctx, a),
                  ),
                ListTile(
                  key: const ValueKey('switch-add'),
                  dense: true,
                  leading: const CircleAvatar(
                    radius: 18,
                    backgroundColor: AppColors.surface,
                    child: Icon(Icons.add, color: AppColors.lime),
                  ),
                  title: const Text('Add account'),
                  onTap: () => Navigator.pop(ctx, 'add'),
                ),
                // v0.0.2: one email + password, many accounts
                ListTile(
                  key: const ValueKey('switch-new-linked'),
                  dense: true,
                  leading: const CircleAvatar(
                    radius: 18,
                    backgroundColor: AppColors.surface,
                    child: Icon(Icons.group_add_outlined, color: AppColors.lime),
                  ),
                  title: const Text('New account, same login'),
                  onTap: () => Navigator.pop(ctx, 'linked'),
                ),
                const SizedBox(height: 6),
              ],
            );
          },
        ),
      ),
    ),
  );
  if (!context.mounted) return;
  if (picked is SavedAccount) {
    await (onSwitch ?? (a) => switchToAccount(context, a))(picked);
  } else if (picked == 'add') {
    await (onAdd ?? () => addAccount(context))();
  } else if (picked == 'linked') {
    await createLinkedAccount(context, me);
  }
}

/// v0.0.2: switch to [uid], an account of the same login (our server
/// gives a one-time sign-in token). false = not switched. [quietDenied]:
/// no message when the account belongs to another login.
Future<bool> switchFamilyAccount(
  BuildContext context,
  String uid, {
  bool quietDenied = false,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final String token;
  try {
    token = await AccountFamily.instance.tokenFor(uid);
  } on ApiException catch (e) {
    if (!(quietDenied && e.statusCode == 403)) {
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    }
    return false;
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('$e')));
    return false;
  }
  if (!context.mounted) return false;
  Navigator.of(context).popUntil((r) => r.isFirst);
  await signOutEverything();
  try {
    await AccountFamily.instance.signInWithToken(token);
  } catch (e) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('Could not switch. Please log in again.')),
    );
  }
  return true;
}

/// A "same login" account of ANOTHER login: log in with that login's
/// password, then open the account.
Future<void> _linkedWithPassword(BuildContext context, SavedAccount a) async {
  final store = SavedAccounts.instance;
  var pw = await store.passwordForEmail(a.email);
  String? error;
  while (true) {
    if (pw == null) {
      if (!context.mounted) return;
      pw = await askAccountPassword(context, a, error: error);
      if (pw == null) return;
    }
    error = await AuthService.instance.checkPassword(a.email, pw);
    if (error == null) break;
    pw = null;
  }
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  Navigator.of(context).popUntil((r) => r.isFirst);
  await signOutEverything();
  try {
    await AuthService.instance.signIn(
      identifier: a.email,
      password: pw,
      openUid: a.uid,
    );
  } on AuthFailure catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

/// v0.0.2: Settings -> Accounts -> "New account, same login".
Future<void> createLinkedAccount(BuildContext context, UserProfile me) async {
  final res = await showModalBottomSheet<(String, String)>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    builder: (_) => const NewLinkedAccountSheet(),
  );
  if (res == null || !context.mounted) return;
  final (username, name) = res;
  // v0.18 Hyper Intelligence: no strong abuse in name / username
  if (!await hiTextOk(context, [name, username]) || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final String uid, token;
  try {
    (uid, token) = await AccountFamily.instance.create(
      username: username,
      name: name,
    );
  } on ApiException catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    return;
  }
  try {
    await SavedAccounts.instance.updateProfile(me);
    await SavedAccounts.instance.rememberFamily([
      FamilyAccount(uid: uid, username: username, name: name),
    ], email: me.email);
  } catch (_) {}
  if (!context.mounted) return;
  Navigator.of(context).popUntil((r) => r.isFirst);
  await signOutEverything();
  try {
    await AccountFamily.instance.signInWithToken(token);
    messenger?.showSnackBar(
      SnackBar(content: Text('Welcome, @$username! Your new account is ready.')),
    );
  } catch (e) {
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('Account made. Log in with your email to open it.'),
      ),
    );
  }
}

/// Username + name for a new "same login" account. Pops (username, name).
class NewLinkedAccountSheet extends StatefulWidget {
  const NewLinkedAccountSheet({super.key, this.usernameCheck});

  /// Tests: is a username free.
  final Future<bool> Function(String name)? usernameCheck;

  @override
  State<NewLinkedAccountSheet> createState() => _NewLinkedAccountSheetState();
}

class _NewLinkedAccountSheetState extends State<NewLinkedAccountSheet> {
  final _user = TextEditingController();
  final _name = TextEditingController();
  UsernameState _state = UsernameState.empty;

  @override
  void dispose() {
    _user.dispose();
    _name.dispose();
    super.dispose();
  }

  bool get _ok => _state == UsernameState.free;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'New account',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          const Text(
            'Same email and password. After logging in you choose the '
            'account.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('linked-username'),
            controller: _user,
            autofocus: true,
            autocorrect: false,
            maxLength: 30,
            decoration: const InputDecoration(
              hintText: 'Username',
              prefixIcon: Icon(Icons.alternate_email),
              counterText: '',
            ),
          ),
          UsernameStatus(
            controller: _user,
            check: widget.usernameCheck,
            onState: (s) {
              if (s != _state && mounted) setState(() => _state = s);
            },
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('linked-name'),
            controller: _name,
            maxLength: 60,
            decoration: const InputDecoration(
              hintText: 'Name (optional)',
              prefixIcon: Icon(Icons.person_outline),
              counterText: '',
            ),
          ),
          const SizedBox(height: 14),
          FilledButton(
            key: const ValueKey('linked-create'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.lime,
              foregroundColor: Colors.black,
            ),
            onPressed: _ok
                ? () => Navigator.pop(context, (
                    _user.text.trim().toLowerCase(),
                    _name.text.trim(),
                  ))
                : null,
            child: const Text(
              'Create account',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

/// v0.0.2: right after logging in. Email login with more than one account
/// -> "Choose account"; username login of another account -> open it.
Future<void> afterLoginChoice(
  BuildContext context,
  String uid, {
  Future<String?> Function(List<FamilyAccount> list)? choose,
}) async {
  final fam = AccountFamily.instance;
  final want = fam.wantUid;
  final ask = fam.askAfterLogin;
  fam
    ..wantUid = ''
    ..askAfterLogin = false;
  if (!ask && want.isEmpty) return;
  List<FamilyAccount> list;
  try {
    list = await fam.refresh();
  } catch (e) {
    debugPrint('accounts: $e');
    return;
  }
  if (!context.mounted) return;
  if (want.isNotEmpty && want != uid) {
    if (list.any((a) => a.uid == want)) {
      await switchFamilyAccount(context, want);
    }
    return;
  }
  // this account was deleted, but others use the same login: open one
  final gone = list.isNotEmpty && !list.any((a) => a.uid == uid);
  if (gone && list.length == 1) {
    await switchFamilyAccount(context, list.first.uid);
    return;
  }
  if (!gone && (!ask || list.length < 2)) return;
  final picked = await (choose ??
      (l) => showChooseAccountSheet(context, l, current: uid))(list);
  if (picked == null || picked == uid || !context.mounted) return;
  await switchFamilyAccount(context, picked);
}

/// "Choose account" (one login, many accounts). Pops the chosen uid.
Future<String?> showChooseAccountSheet(
  BuildContext context,
  List<FamilyAccount> list, {
  required String current,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: AppColors.surface,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 2),
              child: Text(
                'Choose account',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                'Your login has more than one account',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
            for (final a in list)
              ListTile(
                key: ValueKey('choose-account-${a.uid}'),
                leading: Avatar(url: a.photoUrl, name: a.username, size: 40),
                title: Text(
                  '@${a.username}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: a.name.isEmpty
                    ? null
                    : Text(
                        a.name,
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                trailing: a.uid == current
                    ? const Icon(Icons.check_circle, color: AppColors.lime)
                    : const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(ctx, a.uid),
              ),
          ],
        ),
      ),
    ),
  );
}
