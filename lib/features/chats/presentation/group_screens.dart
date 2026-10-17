import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/services/chat_prefs.dart';
import '../../../core/services/media_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../shared/models/post.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/hi_text_check.dart';
import '../../../shared/widgets/verified_badge.dart';
import '../../profile/data/user_repository.dart';
import '../chat_theme.dart';
import '../data/chat_repository.dart';
import '../data/group_repository.dart';
import 'chat_detail_screen.dart';
import 'group_widgets.dart';

/// v0.0.2: opens a group / channel chat.
void openGroupChat(
  BuildContext context,
  String id, {
  String name = '',
  String photoUrl = '',
  bool replace = false,
}) {
  final route = MaterialPageRoute<void>(
    builder: (_) => ChatDetailScreen(
      other: UserProfile(uid: id, name: '', username: name, photoUrl: photoUrl),
    ),
  );
  final nav = Navigator.of(context);
  if (replace) {
    nav.pushReplacement(route);
  } else {
    nav.push(route);
  }
}

/// "+" on the Chats page: New group / New channel / Find channels.
Future<void> showNewChatMenu(BuildContext context) async {
  final what = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.surface,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (id, icon, label, hint) in const [
            ('group', Icons.groups_outlined, 'New group', 'Chat with up to 256 people'),
            ('channel', Icons.campaign_outlined, 'New channel', 'Post to your followers'),
            ('find', Icons.travel_explore, 'Find channels', 'Follow channels you like'),
          ])
            ListTile(
              key: ValueKey('new-chat-$id'),
              leading: Icon(icon, color: AppColors.lime),
              title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(
                hint,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
              ),
              onTap: () => Navigator.pop(ctx, id),
            ),
          const SizedBox(height: 6),
        ],
      ),
    ),
  );
  if (what == null || !context.mounted) return;
  final page = switch (what) {
    'group' => const NewGroupScreen(),
    'channel' => const NewChannelScreen(),
    _ => const FindChannelsScreen(),
  };
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
}

// ===================================================================
// People picker
// ===================================================================

/// Pick people (new group / add people). Returns null when closed.
class PeoplePickerScreen extends StatefulWidget {
  const PeoplePickerScreen({
    super.key,
    required this.title,
    this.button = 'Next',
    this.exclude = const {},
    this.max = GroupRepository.maxGroup - 1,
    this.loadTargets,
    this.search,
  });

  final String title;
  final String button;
  final Set<String> exclude;
  final int max;

  /// Tests: people shown first (default: recent chats + following).
  final Future<List<ChatPerson>> Function()? loadTargets;

  /// Tests: username search.
  final Future<List<ChatPerson>> Function(String q)? search;

  @override
  State<PeoplePickerScreen> createState() => _PeoplePickerScreenState();
}

class _PeoplePickerScreenState extends State<PeoplePickerScreen> {
  List<ChatPerson> _base = const [];
  List<ChatPerson> _found = const [];
  bool _loading = true;
  String _q = '';
  Timer? _debounce;
  final Map<String, ChatPerson> _picked = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await (widget.loadTargets ??
          () => ChatRepository.instance.shareTargets())();
      if (!mounted) return;
      setState(() {
        _base = list
            .where((p) => !p.isGroup && !widget.exclude.contains(p.uid))
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearch(String v) {
    final q = v.trim();
    setState(() => _q = q);
    _debounce?.cancel();
    if (q.isEmpty) {
      setState(() => _found = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final res = await (widget.search ?? _searchUsers)(q);
        if (mounted && _q == q) setState(() => _found = res);
      } catch (_) {}
    });
  }

  static Future<List<ChatPerson>> _searchUsers(String q) async {
    final me = UserRepository.instance.myUid;
    final users = await UserRepository.instance.search(q);
    return [
      for (final u in users)
        if (u.uid != me)
          ChatPerson(uid: u.uid, username: u.username, photoUrl: u.photoUrl, name: u.name),
    ];
  }

  void _toggle(ChatPerson p) {
    setState(() {
      if (_picked.remove(p.uid) == null) {
        if (_picked.length >= widget.max) return;
        _picked[p.uid] = p;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final shown = <String, ChatPerson>{
      for (final p in _base.where((p) => p.matches(_q))) p.uid: p,
      for (final p in _found)
        if (!widget.exclude.contains(p.uid)) p.uid: p,
    }.values.toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          TextButton(
            key: const ValueKey('people-next'),
            onPressed: _picked.isEmpty
                ? null
                : () => Navigator.pop(context, _picked.values.toList()),
            child: Text(
              _picked.isEmpty ? widget.button : '${widget.button} (${_picked.length})',
              style: TextStyle(
                color: _picked.isEmpty ? AppColors.textHint : AppColors.lime,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
            child: TextField(
              key: const ValueKey('people-search'),
              onChanged: _onSearch,
              decoration: InputDecoration(
                hintText: 'Search username',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (_picked.isNotEmpty)
            SizedBox(
              height: 74,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                children: [
                  for (final p in _picked.values)
                    GestureDetector(
                      key: ValueKey('picked-${p.uid}'),
                      onTap: () => _toggle(p),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Column(
                          children: [
                            Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Avatar(url: p.photoUrl, name: p.username, size: 44, photoUid: p.uid),
                                const Positioned(
                                  right: -2,
                                  top: -2,
                                  child: CircleAvatar(
                                    radius: 8,
                                    backgroundColor: AppColors.surfaceHigh,
                                    child: Icon(Icons.close, size: 11),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            SizedBox(
                              width: 56,
                              child: Text(
                                p.username,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : shown.isEmpty
                ? Center(
                    child: Text(
                      _q.isEmpty ? 'Search a username to add people.' : 'Nobody found',
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  )
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final p = shown[i];
                      final on = _picked.containsKey(p.uid);
                      return ListTile(
                        key: ValueKey('person-${p.uid}'),
                        onTap: () => _toggle(p),
                        leading: Avatar(url: p.photoUrl, name: p.username, size: 40, photoUid: p.uid),
                        title: NameBadge(
                          p.username,
                          uid: p.uid,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: p.name.isEmpty
                            ? null
                            : Text(
                                p.name,
                                style: const TextStyle(color: AppColors.textSecondary),
                              ),
                        trailing: Icon(
                          on ? Icons.check_circle : Icons.radio_button_unchecked,
                          color: on ? AppColors.lime : AppColors.textHint,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ===================================================================
// New group / channel
// ===================================================================

/// Photo + name (+ about) form used by new group / new channel / edit.
class _DetailsForm extends StatelessWidget {
  const _DetailsForm({
    required this.channel,
    required this.photo,
    required this.photoUrl,
    required this.onPickPhoto,
    required this.name,
    this.about,
  });

  final bool channel;
  final File? photo;
  final String photoUrl;
  final VoidCallback onPickPhoto;
  final TextEditingController name;
  final TextEditingController? about;

  @override
  Widget build(BuildContext context) {
    final f = photo;
    return Column(
      children: [
        GestureDetector(
          key: const ValueKey('group-photo'),
          onTap: onPickPhoto,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (f != null)
                ClipOval(
                  child: Image.file(f, width: 92, height: 92, fit: BoxFit.cover),
                )
              else
                GroupAvatar(url: photoUrl, channel: channel, size: 92),
              const Positioned(
                right: -2,
                bottom: -2,
                child: CircleAvatar(
                  radius: 15,
                  backgroundColor: AppColors.lime,
                  child: Icon(Icons.photo_camera, size: 16, color: Colors.black),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        TextField(
          key: const ValueKey('group-name'),
          controller: name,
          maxLength: GroupRepository.maxName,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: channel ? 'Channel name' : 'Group name',
          ),
        ),
        if (about != null)
          TextField(
            key: const ValueKey('group-about'),
            controller: about,
            maxLength: GroupRepository.maxAbout,
            minLines: 1,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Description (optional)'),
          ),
      ],
    );
  }
}

Future<File?> _pickPhoto() =>
    MediaService.instance.pickGalleryImage(maxWidth: 800);

class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key});

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  List<ChatPerson>? _people;
  final _name = TextEditingController();
  File? _photo;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _pick());
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final res = await Navigator.of(context).push<List<ChatPerson>>(
      MaterialPageRoute(
        builder: (_) => const PeoplePickerScreen(title: 'New group'),
      ),
    );
    if (!mounted) return;
    if (res == null && _people == null) {
      Navigator.pop(context);
      return;
    }
    if (res != null) setState(() => _people = res);
  }

  Future<void> _create() async {
    final name = GroupRepository.cleanName(_name.text);
    final people = _people ?? const [];
    if (name.isEmpty || people.isEmpty || _busy) return;
    if (!await hiTextOk(context, [name]) || !mounted) return;
    setState(() => _busy = true);
    try {
      final id = await GroupRepository.instance.createGroup(
        name: name,
        members: people,
        photo: _photo,
      );
      if (!mounted) return;
      openGroupChat(context, id, name: name, replace: true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = _people ?? const [];
    return Scaffold(
      appBar: AppBar(title: const Text('New group')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 30),
        children: [
          _DetailsForm(
            channel: false,
            photo: _photo,
            photoUrl: '',
            onPickPhoto: () async {
              final f = await _pickPhoto();
              if (f != null && mounted) setState(() => _photo = f);
            },
            name: _name,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                memberCountText(people.length + 1, channel: false),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              TextButton(onPressed: _pick, child: const Text('Change')),
            ],
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final p in people)
                Chip(
                  avatar: Avatar(url: p.photoUrl, size: 22, photoUid: p.uid),
                  label: Text(p.username),
                  backgroundColor: AppColors.surface,
                  side: const BorderSide(color: AppColors.border),
                ),
            ],
          ),
          const SizedBox(height: 22),
          ListenableBuilder(
            listenable: _name,
            builder: (context, _) => FilledButton(
              key: const ValueKey('group-create'),
              onPressed: _busy || _name.text.trim().isEmpty || people.isEmpty ? null : _create,
              child: Text(_busy ? 'Creating…' : 'Create group'),
            ),
          ),
        ],
      ),
    );
  }
}

class NewChannelScreen extends StatefulWidget {
  const NewChannelScreen({super.key});

  @override
  State<NewChannelScreen> createState() => _NewChannelScreenState();
}

class _NewChannelScreenState extends State<NewChannelScreen> {
  final _name = TextEditingController();
  final _about = TextEditingController();
  File? _photo;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = GroupRepository.cleanName(_name.text);
    if (name.isEmpty || _busy) return;
    if (!await hiTextOk(context, [name, _about.text]) || !mounted) return;
    setState(() => _busy = true);
    try {
      final id = await GroupRepository.instance.createChannel(
        name: name,
        description: _about.text,
        photo: _photo,
      );
      if (!mounted) return;
      openGroupChat(context, id, name: name, replace: true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New channel')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 30),
        children: [
          _DetailsForm(
            channel: true,
            photo: _photo,
            photoUrl: '',
            onPickPhoto: () async {
              final f = await _pickPhoto();
              if (f != null && mounted) setState(() => _photo = f);
            },
            name: _name,
            about: _about,
          ),
          const SizedBox(height: 6),
          const Text(
            'Only admins post. Anyone can find and follow your channel. '
            "Followers can react but can't see who else follows.",
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
          ),
          const SizedBox(height: 22),
          ListenableBuilder(
            listenable: _name,
            builder: (context, _) => FilledButton(
              key: const ValueKey('channel-create'),
              onPressed: _busy || _name.text.trim().isEmpty ? null : _create,
              child: Text(_busy ? 'Creating…' : 'Create channel'),
            ),
          ),
        ],
      ),
    );
  }
}

// ===================================================================
// Find channels
// ===================================================================

class FindChannelsScreen extends StatefulWidget {
  const FindChannelsScreen({super.key, this.search, this.myUid});

  /// Tests: replaces the database search.
  final Future<List<Chat>> Function(String q)? search;
  final String? myUid;

  @override
  State<FindChannelsScreen> createState() => _FindChannelsScreenState();
}

class _FindChannelsScreenState extends State<FindChannelsScreen> {
  Timer? _debounce;
  String _q = '';
  List<Chat>? _list;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _run(String q) async {
    try {
      final res = await (widget.search ?? GroupRepository.instance.searchChannels)(q);
      if (mounted && _q == q) {
        setState(() {
          _list = res;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && _q == q) setState(() => _error = friendlyError(e));
    }
  }

  void _onChanged(String v) {
    final q = v.trim();
    _q = q;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _run(q));
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.myUid ?? ChatRepository.instance.myUid;
    final list = _list;
    return Scaffold(
      appBar: AppBar(title: const Text('Find channels')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
            child: TextField(
              key: const ValueKey('channel-search'),
              onChanged: _onChanged,
              decoration: InputDecoration(
                hintText: 'Search channels',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, textAlign: TextAlign.center),
                    ),
                  )
                : list == null
                ? const Center(child: CircularProgressIndicator())
                : list.isEmpty
                ? const Center(
                    child: Text(
                      'No channels found',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  )
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final c = list[i];
                      final following = c.isMember(me);
                      return ListTile(
                        key: ValueKey('channel-${c.id}'),
                        onTap: () => openGroupChat(context, c.id, name: c.name, photoUrl: c.photoUrl),
                        leading: GroupAvatar(url: c.photoUrl, channel: true, size: 44),
                        title: Text(
                          c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          c.description.isEmpty
                              ? memberCountText(c.members.length, channel: true)
                              : '${memberCountText(c.members.length, channel: true)} · ${c.description}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                        ),
                        trailing: following
                            ? const Text(
                                'Following',
                                style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                              )
                            : const Icon(Icons.chevron_right),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ===================================================================
// Group / channel info
// ===================================================================

class GroupInfoScreen extends StatefulWidget {
  const GroupInfoScreen({super.key, required this.chatId, this.chat, this.myUid});

  final String chatId;

  /// Tests: replaces Firestore.
  final Stream<Chat?>? chat;
  final String? myUid;

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  late final Stream<Chat?> _chat =
      widget.chat ?? ChatRepository.instance.chat(widget.chatId);
  late final String _me = widget.myUid ?? ChatRepository.instance.myUid;
  bool get _live => widget.chat == null;
  final _repo = GroupRepository.instance;
  bool _busy = false;
  final Map<String, UserProfile> _loaded = {};
  final Set<String> _asked = {};

  void _snack(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _do(Future<void> Function() job, {String? done}) async {
    if (_busy || !_live) return;
    setState(() => _busy = true);
    try {
      await job();
      if (done != null) _snack(done);
    } catch (e) {
      _snack(friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Names missing in memberInfo (older data) are read once.
  void _loadMissing(Chat c, List<String> uids) {
    final missing = uids
        .where((u) => c.usernameOf(u).isEmpty && !_asked.contains(u))
        .take(30)
        .toList();
    if (missing.isEmpty || !_live) return;
    _asked.addAll(missing);
    UserRepository.instance.usersByIds(missing).then((users) {
      if (!mounted) return;
      setState(() {
        for (final u in users) {
          _loaded[u.uid] = u;
        }
      });
    }).catchError((Object e) {
      debugPrint('members: $e');
    });
  }

  String _name(Chat c, String uid) {
    final n = c.usernameOf(uid);
    if (n.isNotEmpty) return n;
    return _loaded[uid]?.username ?? '…';
  }

  String _photoOf(Chat c, String uid) {
    final p = c.photoOf(uid);
    return p.isNotEmpty ? p : (_loaded[uid]?.photoUrl ?? '');
  }

  Future<void> _edit(Chat c) async {
    final name = TextEditingController(text: c.name);
    final about = TextEditingController(text: c.description);
    File? photo;
    var remove = false;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            8,
            20,
            20 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DetailsForm(
                  channel: c.isChannel,
                  photo: photo,
                  photoUrl: remove ? '' : c.photoUrl,
                  onPickPhoto: () async {
                    final f = await _pickPhoto();
                    if (f != null) setSheet(() => photo = f);
                  },
                  name: name,
                  about: about,
                ),
                if (c.photoUrl.isNotEmpty && photo == null && !remove)
                  TextButton(
                    onPressed: () => setSheet(() => remove = true),
                    child: const Text('Remove photo', style: TextStyle(color: AppColors.like)),
                  ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('group-save'),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final n = name.text;
    final a = about.text;
    name.dispose();
    about.dispose();
    if (ok != true || !mounted) return;
    if (!await hiTextOk(context, [n, a]) || !mounted) return;
    await _do(
      () => _repo.edit(c, name: n, description: a, photo: photo, removePhoto: remove),
      done: 'Saved',
    );
  }

  Future<void> _addPeople(Chat c) async {
    final res = await Navigator.of(context).push<List<ChatPerson>>(
      MaterialPageRoute(
        builder: (_) => PeoplePickerScreen(
          title: 'Add people',
          button: 'Add',
          exclude: c.members.toSet(),
          max: GroupRepository.maxGroup - c.members.length,
        ),
      ),
    );
    if (res == null || res.isEmpty || !mounted) return;
    await _do(() => _repo.addMembers(c, res), done: 'Added');
  }

  /// Channel admins add another admin (must follow the channel).
  Future<void> _addAdmin(Chat c) async {
    final res = await Navigator.of(context).push<List<ChatPerson>>(
      MaterialPageRoute(
        builder: (_) => PeoplePickerScreen(
          title: 'Add admin',
          button: 'Add',
          exclude: c.admins.toSet(),
          max: 1,
        ),
      ),
    );
    if (res == null || res.isEmpty || !mounted) return;
    final p = res.first;
    if (!c.isMember(p.uid)) {
      _snack('${p.username} must follow the channel first.');
      return;
    }
    await _do(() => _repo.setAdmin(c, p.uid, true), done: '${p.username} is now an admin');
  }

  Future<void> _memberMenu(Chat c, String uid) async {
    final admin = c.isAdmin(_me);
    final name = _name(c, uid);
    if (uid == _me) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
              child: Text(name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            ),
            for (final (id, icon, label, show) in [
              ('profile', Icons.person_outline, 'View profile', true),
              ('message', Icons.chat_bubble_outline, 'Message $name', true),
              ('admin', Icons.shield_outlined, 'Make admin', admin && !c.isAdmin(uid)),
              ('unadmin', Icons.remove_moderator_outlined, 'Remove as admin', admin && c.isAdmin(uid)),
              ('remove', Icons.person_remove_outlined, c.isChannel ? 'Remove from channel' : 'Remove from group', admin),
            ])
              if (show)
                ListTile(
                  key: ValueKey('member-$id'),
                  leading: Icon(icon, color: id == 'remove' ? AppColors.like : null),
                  title: Text(
                    label,
                    style: TextStyle(
                      color: id == 'remove' ? AppColors.like : null,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () => Navigator.pop(ctx, id),
                ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'profile':
        openProfile(context, uid);
      case 'message':
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ChatDetailScreen(
              other: UserProfile(uid: uid, name: '', username: name, photoUrl: _photoOf(c, uid)),
            ),
          ),
        );
      case 'admin':
        await _do(() => _repo.setAdmin(c, uid, true), done: '$name is now an admin');
      case 'unadmin':
        await _do(() => _repo.setAdmin(c, uid, false));
      case 'remove':
        await _do(() => _repo.removeMember(c, uid), done: '$name removed');
    }
  }

  Future<void> _leave(Chat c) async {
    final channel = c.isChannel;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(channel ? 'Unfollow ${c.name}?' : 'Leave ${c.name}?'),
        content: Text(
          channel
              ? "You won't get its posts any more."
              : "You won't get its messages any more. Admins can add you again.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            key: const ValueKey('group-leave-yes'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              channel ? 'Unfollow' : 'Leave',
              style: const TextStyle(color: AppColors.like),
            ),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    // the last person: just remove it from your list
    if (!channel && c.members.length <= 1) {
      await _do(() => ChatPrefs.instance.deleteChat(c.id));
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
      return;
    }
    await _do(() => _repo.leave(c));
    if (mounted && !channel) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Info')),
      body: StreamBuilder<Chat?>(
        stream: _chat,
        builder: (context, snap) {
          final c = snap.data;
          if (snap.hasError) {
            return const Center(
              child: Text(
                "You're no longer a member.",
                style: TextStyle(color: AppColors.textSecondary),
              ),
            );
          }
          if (c == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return _body(c);
        },
      ),
    );
  }

  Widget _body(Chat c) {
    final channel = c.isChannel;
    final admin = c.isAdmin(_me);
    final member = c.isMember(_me);
    final people = channel
        ? [...c.admins]
        : ([...c.members]..sort((a, b) {
            final x = (c.isAdmin(b) ? 1 : 0) - (c.isAdmin(a) ? 1 : 0);
            if (x != 0) return x;
            if (a == _me) return -1;
            if (b == _me) return 1;
            return _name(c, a).toLowerCase().compareTo(_name(c, b).toLowerCase());
          }));
    _loadMissing(c, people);
    return ValueListenableBuilder<ChatPrefsData>(
      valueListenable: ChatPrefs.instance.value,
      builder: (context, prefs, _) {
        final muted = prefs.isMuted(c.id);
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 40),
          children: [
            Center(child: GroupAvatar(url: c.photoUrl, channel: channel, size: 96)),
            const SizedBox(height: 12),
            Text(
              c.name,
              key: const ValueKey('info-name'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 3),
            Text(
              '${channel ? 'Channel' : 'Group'} · ${memberCountText(c.members.length, channel: channel)}',
              key: const ValueKey('info-count'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            if (c.description.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(c.description, textAlign: TextAlign.center),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (member)
                  _RoundAction(
                    key: const ValueKey('info-mute'),
                    icon: muted ? Icons.notifications_off_outlined : Icons.notifications_none,
                    label: muted ? 'Unmute' : 'Mute',
                    onTap: () => _do(() => ChatPrefs.instance.toggleMuteChat(c.id)),
                  ),
                _RoundAction(
                  key: const ValueKey('info-theme'),
                  icon: Icons.palette_outlined,
                  label: 'Theme',
                  onTap: () => showChatThemePicker(context, c.id),
                ),
                if (admin)
                  _RoundAction(
                    key: const ValueKey('info-edit'),
                    icon: Icons.edit_outlined,
                    label: 'Edit',
                    onTap: () => _edit(c),
                  ),
                if (admin && !channel)
                  _RoundAction(
                    key: const ValueKey('info-add'),
                    icon: Icons.person_add_alt,
                    label: 'Add',
                    onTap: () => _addPeople(c),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Text(
                  channel ? 'Admins' : memberCountText(c.members.length, channel: false),
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
                const Spacer(),
                if (admin && channel)
                  TextButton(
                    key: const ValueKey('info-add-admin'),
                    onPressed: () => _addAdmin(c),
                    child: const Text('Add admin'),
                  ),
              ],
            ),
            for (final uid in people)
              ListTile(
                key: ValueKey('member-$uid'),
                contentPadding: EdgeInsets.zero,
                onTap: uid == _me ? null : () => _memberMenu(c, uid),
                leading: Avatar(url: _photoOf(c, uid), name: _name(c, uid), size: 40, photoUid: uid),
                title: Row(
                  children: [
                    Flexible(
                      child: NameBadge(
                        uid == _me ? 'You' : _name(c, uid),
                        uid: uid,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                trailing: c.isAdmin(uid)
                    ? Container(
                        key: ValueKey('admin-chip-$uid'),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          border: Border.all(color: AppColors.lime),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Text(
                          'Admin',
                          style: TextStyle(color: AppColors.lime, fontSize: 11.5, fontWeight: FontWeight.w700),
                        ),
                      )
                    : null,
              ),
            const SizedBox(height: 18),
            if (member)
              OutlinedButton.icon(
                key: const ValueKey('group-leave'),
                onPressed: _busy ? null : () => _leave(c),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.like,
                  side: const BorderSide(color: AppColors.border),
                ),
                icon: const Icon(Icons.logout),
                label: Text(channel ? 'Unfollow channel' : 'Leave group'),
              )
            else if (channel)
              FilledButton(
                key: const ValueKey('info-follow'),
                onPressed: _busy ? null : () => _do(() => _repo.join(c), done: 'Following'),
                child: const Text('Follow'),
              ),
          ],
        );
      },
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({super.key, required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          width: 72,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              Icon(icon, size: 22, color: AppColors.lime),
              const SizedBox(height: 4),
              Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}
