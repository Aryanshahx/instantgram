import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/app_user.dart';
import '../services/chat_service.dart';
import '../services/user_service.dart';
import 'avatar.dart';

/// The people picked in [pickRecipients], and the optional note typed with them.
class RecipientPick {
  const RecipientPick(this.users, this.note);
  final List<AppUser> users;
  final String note;
}

/// A sheet to choose who to send something to (people you chat with, people you follow, or
/// anyone found by name).
Future<RecipientPick?> pickRecipients(
  BuildContext context, {
  required String title,
  String actionLabel = 'Send',
  bool withNote = false,
  Future<List<AppUser>> Function()? loadSuggestions,
  Future<List<AppUser>> Function(String query)? search,
  VoidCallback? onShareLink,
}) {
  return showModalBottomSheet<RecipientPick>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.85,
      child: RecipientSheet(
        title: title,
        actionLabel: actionLabel,
        withNote: withNote,
        loadSuggestions: loadSuggestions ?? defaultSuggestions,
        search: search ?? UserService.instance.searchUsers,
        onShareLink: onShareLink,
      ),
    ),
  );
}

/// People you chatted with lately, then people you follow.
Future<List<AppUser>> defaultSuggestions() async {
  final me = UserService.instance.myUid;
  final ids = <String>[];
  for (final t in ChatService.instance.threads.value) {
    final o = t.other(me);
    if (o != me && !ids.contains(o)) ids.add(o);
  }
  try {
    for (final id in await UserService.instance.followingIds()) {
      if (id != me && !ids.contains(id)) ids.add(id);
      if (ids.length >= 40) break;
    }
  } catch (_) {
    // the chat list alone is fine
  }
  return UserService.instance.getUsers(ids.take(40));
}

String _myUid() {
  try {
    return UserService.instance.myUid;
  } catch (_) {
    return '';
  }
}

class RecipientSheet extends StatefulWidget {
  const RecipientSheet({
    super.key,
    required this.title,
    required this.actionLabel,
    required this.withNote,
    required this.loadSuggestions,
    required this.search,
    this.onShareLink,
  });

  /// Shows a "Share link" row at the top (WhatsApp, Messages... through the phone's share
  /// menu), so people and link sharing are on the same screen.
  final VoidCallback? onShareLink;

  final String title;
  final String actionLabel;
  final bool withNote;
  final Future<List<AppUser>> Function() loadSuggestions;
  final Future<List<AppUser>> Function(String query) search;

  @override
  State<RecipientSheet> createState() => _RecipientSheetState();
}

class _RecipientSheetState extends State<RecipientSheet> {
  final _q = TextEditingController();
  final _note = TextEditingController();
  Timer? _debounce;
  List<AppUser> _suggested = const [];
  List<AppUser>? _found;
  bool _loading = true;
  final Map<String, AppUser> _picked = {};

  @override
  void initState() {
    super.initState();
    widget
        .loadSuggestions()
        .then((l) {
          if (mounted) {
            setState(() {
              _suggested = l;
              _loading = false;
            });
          }
        })
        .catchError((Object _) {
          if (mounted) setState(() => _loading = false);
        });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    _note.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    final q = v.trim();
    if (q.isEmpty) {
      setState(() => _found = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final r = await widget.search(q);
        if (mounted && _q.text.trim() == q) {
          final me = _myUid();
          setState(() => _found = r.where((u) => u.uid != me).toList());
        }
      } catch (_) {
        if (mounted) setState(() => _found = const []);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final list = _found ?? _suggested;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              key: const ValueKey('recipientSearch'),
              controller: _q,
              onChanged: _changed,
              decoration: const InputDecoration(
                hintText: 'Search people',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
          if (widget.onShareLink != null)
            ListTile(
              key: const ValueKey('shareLink'),
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppTheme.volt.withValues(alpha: 0.25),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.ios_share_rounded),
              ),
              title: const Text(
                'Share link',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: const Text('WhatsApp, Messages and other apps'),
              onTap: widget.onShareLink,
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : list.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _found != null
                            ? 'Nobody found.'
                            : 'Search for a person to send to.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.muted),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final u = list[i];
                      final on = _picked.containsKey(u.uid);
                      return ListTile(
                        key: ValueKey('recipient_${u.uid}'),
                        leading: UserAvatar(
                          url: u.photoUrl,
                          name: u.username,
                          radius: 22,
                          uid: u.uid,
                        ),
                        title: Text(
                          u.username,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: u.fullName.isEmpty ? null : Text(u.fullName),
                        trailing: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            color: on ? AppTheme.volt : Colors.transparent,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: on ? AppTheme.volt : context.hairline,
                              width: 2,
                            ),
                          ),
                          child: on
                              ? const Icon(
                                  Icons.check_rounded,
                                  size: 17,
                                  color: AppTheme.ink,
                                )
                              : null,
                        ),
                        onTap: () => setState(() {
                          if (on) {
                            _picked.remove(u.uid);
                          } else {
                            _picked[u.uid] = u;
                          }
                        }),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.withNote && _picked.isNotEmpty) ...[
                  TextField(
                    key: const ValueKey('shareNote'),
                    controller: _note,
                    maxLength: 300,
                    buildCounter:
                        (
                          _, {
                          required currentLength,
                          required isFocused,
                          maxLength,
                        }) => null,
                    decoration: const InputDecoration(
                      hintText: 'Add a message (optional)',
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('recipientSend'),
                    onPressed: _picked.isEmpty
                        ? null
                        : () => Navigator.pop(
                            context,
                            RecipientPick(_picked.values.toList(), _note.text),
                          ),
                    child: Text(
                      _picked.isEmpty
                          ? widget.actionLabel
                          : '${widget.actionLabel} (${_picked.length})',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
