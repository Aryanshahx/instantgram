import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../services/story_views.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
import 'settings_widgets.dart';

/// Settings > Moment view alerts: the people whose views of my moments I hear about
/// (a notification the first time they watch each moment).
class StoryAlertsScreen extends StatefulWidget {
  const StoryAlertsScreen({super.key, this.lookUp, this.search});

  /// Tests: replace the profile lookups.
  final Future<List<AppUser>> Function(List<String> uids)? lookUp;
  final Future<List<AppUser>> Function(String query)? search;

  @override
  State<StoryAlertsScreen> createState() => _StoryAlertsScreenState();
}

class _StoryAlertsScreenState extends State<StoryAlertsScreen> {
  final _q = TextEditingController();
  List<AppUser>? _people;
  List<AppUser> _found = [];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<List<AppUser>> _lookUp(List<String> ids) =>
      widget.lookUp?.call(ids) ?? UserService.instance.getUsers(ids);

  Future<void> _load() async {
    try {
      final ids = await StoryViews.instance.alerts();
      final users = await _lookUp(ids);
      if (mounted) setState(() => _people = users);
    } catch (_) {
      if (mounted) setState(() => _people = []);
    }
  }

  void _onQuery(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final q = v.trim();
      if (q.isEmpty) {
        if (mounted) setState(() => _found = []);
        return;
      }
      try {
        final test = widget.search;
        final List<AppUser> r;
        if (test != null) {
          r = await test(q);
        } else {
          final me = UserService.instance.myUid;
          r = [
            for (final u in await UserService.instance.searchUsers(q))
              if (u.uid != me) u,
          ];
        }
        if (mounted) setState(() => _found = r);
      } catch (_) {
        // keep the old results
      }
    });
  }

  Future<void> _set(AppUser u, bool on) async {
    try {
      await StoryViews.instance.setAlert(u.uid, on);
      if (!mounted) return;
      setState(() {
        final list = [...?_people]..removeWhere((p) => p.uid == u.uid);
        if (on) list.add(u);
        _people = list;
      });
    } catch (_) {
      if (mounted) showToast(context, 'Could not save. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    final chosen = {for (final p in people ?? const <AppUser>[]) p.uid};
    return SettingsPage(
      title: context.tr('Moment view alerts'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
          child: Text(
            'Get a notification the first time these people watch one of your moments.',
            style: TextStyle(color: context.muted),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            key: const ValueKey('alertSearch'),
            controller: _q,
            onChanged: _onQuery,
            decoration: InputDecoration(
              hintText: 'Add someone',
              prefixIcon: const Icon(Icons.person_search_rounded),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
        for (final u in _found)
          ListTile(
            key: ValueKey('alertFound_${u.uid}'),
            leading: UserAvatar(url: u.photoUrl, name: u.username),
            title: Text(u.username),
            trailing: chosen.contains(u.uid)
                ? const Icon(Icons.check_rounded, color: AppTheme.volt)
                : const Icon(Icons.add_circle_outline_rounded),
            onTap: chosen.contains(u.uid) ? null : () => _set(u, true),
          ),
        SettingsHeading(context.tr('Alerts on')),
        if (people == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (people.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              'Nobody yet. You can also tap the bell next to a viewer of your moment.',
              style: TextStyle(color: context.muted),
            ),
          )
        else
          for (final u in people)
            ListTile(
              key: ValueKey('alertPerson_${u.uid}'),
              leading: UserAvatar(url: u.photoUrl, name: u.username),
              title: Text(u.username),
              trailing: IconButton(
                key: ValueKey('alertRemove_${u.uid}'),
                tooltip: 'Remove',
                icon: const Icon(Icons.notifications_off_outlined),
                onPressed: () => _set(u, false),
              ),
            ),
      ],
    );
  }
}
