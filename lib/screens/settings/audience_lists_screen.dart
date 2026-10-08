import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../models/audience.dart';
import '../../services/audience_service.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
import 'settings_widgets.dart';

/// Profile lookups; tests replace them.
class AudiencePeople {
  static Future<List<AppUser>> Function(List<String> uids)? lookUp;
  static Future<List<AppUser>> Function(String query)? search;

  static Future<List<AppUser>> get(List<String> uids) =>
      lookUp?.call(uids) ?? UserService.instance.getUsers(uids);

  static Future<List<AppUser>> find(String q) async {
    final s = search;
    if (s != null) return s(q);
    final me = UserService.instance.myUid;
    return [
      for (final u in await UserService.instance.searchUsers(q))
        if (u.uid != me) u,
    ];
  }
}

/// Settings > Audience lists: up to 10 lists of people to share moments with.
class AudienceListsScreen extends StatefulWidget {
  const AudienceListsScreen({super.key});

  @override
  State<AudienceListsScreen> createState() => _AudienceListsScreenState();
}

class _AudienceListsScreenState extends State<AudienceListsScreen> {
  List<AudienceList>? _lists;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await AudienceService.instance.lists();
      if (mounted) setState(() => _lists = l);
    } catch (_) {
      if (mounted) setState(() => _lists = []);
    }
  }

  Future<void> _edit(AudienceList? list) async {
    final saved = await editAudienceList(context, list);
    if (saved != null) await _load();
  }

  Future<void> _delete(AudienceList l) async {
    final ok = await confirm(
      context,
      title: 'Delete "${l.name}"?',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    try {
      await AudienceService.instance.delete(l.id);
      await _load();
    } catch (_) {
      if (mounted) showToast(context, 'Could not delete. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final lists = _lists;
    return SettingsPage(
      title: context.tr('Audience lists'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(
            'Share a moment with just one list: close friends, family, a team. Only the people on it see it.',
            style: TextStyle(color: context.muted),
          ),
        ),
        if (lists == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else ...[
          for (final l in lists)
            ListTile(
              key: ValueKey('audList_${l.id}'),
              leading: const CircleAvatar(
                backgroundColor: AppTheme.volt,
                child: Icon(Icons.group_rounded, color: AppTheme.ink),
              ),
              title: Text(
                l.name,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                '${l.members.length} ${l.members.length == 1 ? 'person' : 'people'}',
              ),
              onTap: () => _edit(l),
              trailing: IconButton(
                key: ValueKey('audDelete_${l.id}'),
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () => _delete(l),
              ),
            ),
          if (lists.length < AudienceList.maxLists)
            ListTile(
              key: const ValueKey('audNew'),
              leading: const CircleAvatar(child: Icon(Icons.add_rounded)),
              title: const Text('New list'),
              onTap: () => _edit(null),
            ),
        ],
      ],
    );
  }
}

/// Opens the list editor; returns the saved list, or null.
Future<AudienceList?> editAudienceList(
  BuildContext context,
  AudienceList? list,
) => Navigator.of(context).push<AudienceList>(
  MaterialPageRoute(builder: (_) => AudienceListEditScreen(list: list)),
);

class AudienceListEditScreen extends StatefulWidget {
  const AudienceListEditScreen({super.key, this.list});

  /// Null = a new list.
  final AudienceList? list;

  @override
  State<AudienceListEditScreen> createState() => _AudienceListEditScreenState();
}

class _AudienceListEditScreenState extends State<AudienceListEditScreen> {
  late final TextEditingController _name = TextEditingController(
    text: widget.list?.name ?? '',
  );
  final _q = TextEditingController();
  final List<AppUser> _members = [];
  List<AppUser> _found = [];
  Timer? _debounce;
  bool _saving = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _q.dispose();
    super.dispose();
  }

  Future<void> _loadMembers() async {
    final ids = widget.list?.members ?? const <String>[];
    try {
      final users = ids.isEmpty ? <AppUser>[] : await AudiencePeople.get(ids);
      if (mounted) setState(() => _members.addAll(users));
    } catch (_) {
      // shown empty
    }
    if (mounted) setState(() => _loading = false);
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
        final r = await AudiencePeople.find(q);
        if (mounted) setState(() => _found = r);
      } catch (_) {
        // keep the old results
      }
    });
  }

  void _add(AppUser u) {
    if (_members.any((m) => m.uid == u.uid)) return;
    if (_members.length >= AudienceList.maxMembers) {
      showToast(
        context,
        'A list can have up to ${AudienceList.maxMembers} people.',
      );
      return;
    }
    setState(() => _members.add(u));
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final saved = await AudienceService.instance.save(
        AudienceList(
          id: widget.list?.id ?? '',
          name: _name.text,
          members: [for (final m in _members) m.uid],
        ),
      );
      if (mounted) Navigator.of(context).pop(saved);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      showToast(context, 'Could not save. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final chosen = {for (final m in _members) m.uid};
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.list == null ? 'New list' : 'Edit list'),
        actions: [
          TextButton(
            key: const ValueKey('audSave'),
            onPressed: _saving ? null : _save,
            child: const Text(
              'Save',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const ValueKey('audName'),
              controller: _name,
              maxLength: 30,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'List name',
                hintText: 'Close friends',
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const ValueKey('audSearch'),
              controller: _q,
              onChanged: _onQuery,
              decoration: InputDecoration(
                hintText: 'Add people',
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
              key: ValueKey('audFound_${u.uid}'),
              leading: UserAvatar(url: u.photoUrl, name: u.username),
              title: Text(u.username),
              trailing: chosen.contains(u.uid)
                  ? const Icon(Icons.check_rounded, color: AppTheme.volt)
                  : const Icon(Icons.add_circle_outline_rounded),
              onTap: chosen.contains(u.uid) ? null : () => _add(u),
            ),
          SettingsHeading(
            '${_members.length} ${_members.length == 1 ? 'person' : 'people'}',
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            for (final m in _members)
              ListTile(
                key: ValueKey('audMember_${m.uid}'),
                leading: UserAvatar(url: m.photoUrl, name: m.username),
                title: Text(m.username),
                trailing: IconButton(
                  key: ValueKey('audRemove_${m.uid}'),
                  tooltip: 'Remove',
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                  onPressed: () => setState(
                    () => _members.removeWhere((x) => x.uid == m.uid),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
