import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/audience.dart';
import '../screens/settings/audience_lists_screen.dart';
import '../services/audience_service.dart';

/// Who a new moment is for. Returns the choice, or null when dismissed.
Future<StoryAudience?> pickStoryAudience(
  BuildContext context,
  StoryAudience current,
) => showModalBottomSheet<StoryAudience>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _AudienceSheet(current: current),
);

class _AudienceSheet extends StatefulWidget {
  const _AudienceSheet({required this.current});
  final StoryAudience current;

  @override
  State<_AudienceSheet> createState() => _AudienceSheetState();
}

class _AudienceSheetState extends State<_AudienceSheet> {
  List<AudienceList>? _lists;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool fresh = false}) async {
    try {
      final l = await AudienceService.instance.lists(fresh: fresh);
      if (mounted) setState(() => _lists = l);
    } catch (_) {
      if (mounted) setState(() => _lists = []);
    }
  }

  Future<void> _new() async {
    final saved = await editAudienceList(context, null);
    if (saved == null || !mounted) return;
    Navigator.of(context).pop(StoryAudience.only(saved));
  }

  Future<void> _edit(AudienceList l) async {
    final saved = await editAudienceList(context, l);
    if (saved != null) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final lists = _lists;
    final cur = widget.current.list?.id;
    Widget tile({
      required Key key,
      required IconData icon,
      required String title,
      String? subtitle,
      required bool selected,
      required VoidCallback onTap,
      Widget? trailing,
    }) => ListTile(
      key: key,
      leading: CircleAvatar(
        backgroundColor: selected ? AppTheme.volt : null,
        child: Icon(icon, color: selected ? AppTheme.ink : null),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing:
          trailing ??
          (selected
              ? const Icon(Icons.check_circle_rounded, color: AppTheme.volt)
              : null),
      onTap: onTap,
    );
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Who can see this moment?',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
            ),
          ),
          tile(
            key: const ValueKey('aud_everyone'),
            icon: Icons.public_rounded,
            title: 'Everyone',
            subtitle: 'Your followers',
            selected: cur == null,
            onTap: () =>
                Navigator.of(context).pop(const StoryAudience.everyone()),
          ),
          if (lists == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            for (final l in lists)
              tile(
                key: ValueKey('aud_${l.id}'),
                icon: Icons.group_rounded,
                title: l.name,
                subtitle:
                    '${l.members.length} ${l.members.length == 1 ? 'person' : 'people'}',
                selected: cur == l.id,
                onTap: () => Navigator.of(context).pop(StoryAudience.only(l)),
                trailing: IconButton(
                  key: ValueKey('audEdit_${l.id}'),
                  tooltip: 'Edit',
                  icon: Icon(
                    cur == l.id ? Icons.edit_rounded : Icons.edit_outlined,
                  ),
                  onPressed: () => _edit(l),
                ),
              ),
          if (lists != null && lists.length < AudienceList.maxLists)
            ListTile(
              key: const ValueKey('aud_new'),
              leading: const CircleAvatar(child: Icon(Icons.add_rounded)),
              title: const Text('New list'),
              onTap: _new,
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
