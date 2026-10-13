import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/services/media_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/ig_buttons.dart';
import '../../../shared/widgets/ig_text_field.dart';
import '../../../shared/widgets/net_image.dart';
import '../data/user_repository.dart';
import 'profile_image_crop.dart';

/// Lower case letters, numbers, "." and "_" only.
class UsernameFormatter extends TextInputFormatter {
  const UsernameFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final t = newValue.text.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9._]'),
      '',
    );
    if (t == newValue.text) return newValue;
    final cut = newValue.text.length - t.length;
    final off = (newValue.selection.baseOffset - cut).clamp(0, t.length);
    return TextEditingValue(
      text: t,
      selection: TextSelection.collapsed(offset: off),
    );
  }
}

enum _NameState { same, checking, free, taken, invalid }

class _LinkRow {
  _LinkRow(ProfileLink? l)
    : title = TextEditingController(text: l?.title ?? ''),
      url = TextEditingController(text: l?.url ?? '');
  final TextEditingController title;
  final TextEditingController url;

  void dispose() {
    title.dispose();
    url.dispose();
  }
}

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key, required this.profile});

  final UserProfile profile;

  /// Tests replace the username check (no Firestore).
  @visibleForTesting
  static Future<bool> Function(String name)? debugUsernameFree;

  /// Tests give the live profile (no Firestore).
  @visibleForTesting
  static Stream<UserProfile?> Function(String uid)? debugLive;

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final _name = TextEditingController(text: widget.profile.name);
  late final _username = TextEditingController(text: widget.profile.username);
  late final _bio = TextEditingController(text: widget.profile.bio);
  late final List<_LinkRow> _links = [
    for (final l in widget.profile.allLinks.take(UserProfile.maxLinks))
      _LinkRow(l),
  ];
  late final Stream<UserProfile?> _live =
      (EditProfileScreen.debugLive ?? UserRepository.instance.watchUser)(
        widget.profile.uid,
      );
  bool _saving = false;
  _NameState _nameState = _NameState.same;
  String _nameProblem = '';
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _username.dispose();
    _bio.dispose();
    for (final l in _links) {
      l.dispose();
    }
    super.dispose();
  }

  // ---------------- username ----------------

  void _onUsername(String v) {
    _debounce?.cancel();
    final n = v.trim();
    if (n == widget.profile.username) {
      setState(() => _nameState = _NameState.same);
      return;
    }
    final problem = UserRepository.usernameProblem(n);
    if (problem.isNotEmpty) {
      setState(() {
        _nameState = _NameState.invalid;
        _nameProblem = problem;
      });
      return;
    }
    setState(() => _nameState = _NameState.checking);
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      try {
        final check =
            EditProfileScreen.debugUsernameFree ??
            UserRepository.instance.usernameFree;
        final free = await check(n);
        if (!mounted || _username.text.trim() != n) return;
        setState(() => _nameState = free ? _NameState.free : _NameState.taken);
      } catch (_) {
        if (mounted) setState(() => _nameState = _NameState.same);
      }
    });
  }

  Widget _usernameStatus() {
    final (IconData? icon, Color color, String text) = switch (_nameState) {
      _NameState.same => (null, AppColors.textSecondary, ''),
      _NameState.checking => (
        Icons.hourglass_empty,
        AppColors.textSecondary,
        'Checking…',
      ),
      _NameState.free => (Icons.check_circle, AppColors.lime, 'Available'),
      _NameState.taken => (Icons.cancel, AppColors.like, 'Already taken'),
      _NameState.invalid => (Icons.error_outline, AppColors.like, _nameProblem),
    };
    if (icon == null) {
      return const Padding(
        padding: EdgeInsets.only(left: 4, top: 6),
        child: Text(
          'Letters, numbers, . and _ (3-30). Must be unique.',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      );
    }
    return Padding(
      key: ValueKey('username-${_nameState.name}'),
      padding: const EdgeInsets.only(left: 4, top: 6),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- links ----------------

  void _addLink() {
    if (_links.length >= UserProfile.maxLinks) return;
    setState(() => _links.add(_LinkRow(null)));
  }

  void _removeLink(int i) {
    final row = _links.removeAt(i);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => row.dispose());
  }

  /// Clean links, or an error text.
  (List<ProfileLink>, String) _readLinks() {
    final out = <ProfileLink>[];
    for (var i = 0; i < _links.length; i++) {
      final title = _links[i].title.text.trim();
      final raw = _links[i].url.text.trim();
      if (raw.isEmpty && title.isEmpty) continue;
      final url = ProfileLink.fixUrl(raw);
      if (url.isEmpty) return (const [], 'Link ${i + 1}: enter a web address');
      out.add(
        ProfileLink(
          title: title.length > ProfileLink.maxTitle
              ? title.substring(0, ProfileLink.maxTitle)
              : title,
          url: url,
        ),
      );
    }
    return (out, '');
  }

  // ---------------- save ----------------

  void _snack(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _save() async {
    final newName = _username.text.trim();
    final changeName = newName != widget.profile.username;
    if (changeName) {
      final problem = UserRepository.usernameProblem(newName);
      if (problem.isNotEmpty) return _snack('Username: $problem');
      if (_nameState == _NameState.taken) {
        return _snack('That username is taken');
      }
    }
    final (links, error) = _readLinks();
    if (error.isNotEmpty) return _snack(error);
    setState(() => _saving = true);
    try {
      if (changeName) {
        await UserRepository.instance.changeUsername(newName);
      }
      await UserRepository.instance.updateProfile(
        name: _name.text,
        bio: _bio.text,
        links: links,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) _snack('Could not save: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------------- photo / banner ----------------

  Future<void> _pick({required bool cover}) async {
    final spec = cover ? ProfileImageSpec.banner : ProfileImageSpec.photo;
    final picked = await MediaService.instance.pick(context, maxWidth: 2400);
    if (picked == null || !mounted) return;
    final file = await cropProfileImage(context, picked, spec);
    if (file == null || !mounted) return;
    final ok = await runWithProgress(
      context,
      title: cover ? 'Updating banner' : 'Updating photo',
      task: (p) => cover
          ? UserRepository.instance.changeCover(file, onProgress: p)
          : UserRepository.instance.changePhoto(file, onProgress: p),
    );
    if (ok && mounted) _snack(cover ? 'Banner updated' : 'Photo updated');
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: StreamBuilder<UserProfile?>(
        stream: _live,
        initialData: widget.profile,
        builder: (context, snap) {
          final p = snap.data ?? widget.profile;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _label('Banner'),
              _banner(p),
              _hint(ProfileImageSpec.banner.hint),
              const SizedBox(height: 16),
              Row(
                children: [
                  Avatar(url: p.photoUrl, name: p.displayName, size: 64),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Profile photo',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          ProfileImageSpec.photo.hint,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        SizedBox(
                          height: 32,
                          child: OutlinedButton.icon(
                            key: const ValueKey('edit-photo'),
                            onPressed: () => _pick(cover: false),
                            icon: const Icon(
                              Icons.photo_camera_outlined,
                              size: 16,
                            ),
                            label: const Text('Change photo'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _label('Name'),
              IgTextField(
                height: 46,
                hint: 'Your name',
                icon: Icons.person_outline,
                controller: _name,
                maxLength: 60,
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 12),
              _label('Username'),
              IgTextField(
                fieldKey: const ValueKey('edit-username'),
                height: 46,
                hint: 'username',
                icon: Icons.alternate_email,
                controller: _username,
                maxLength: 30,
                inputFormatters: const [UsernameFormatter()],
                onChanged: _onUsername,
              ),
              _usernameStatus(),
              const SizedBox(height: 12),
              _label('Bio'),
              IgTextField(
                height: 46,
                hint: 'Tell people about yourself',
                controller: _bio,
                maxLines: 4,
                maxLength: 300,
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 14),
              _label('Links (up to ${UserProfile.maxLinks})'),
              for (var i = 0; i < _links.length; i++) _linkRow(i),
              if (_links.length < UserProfile.maxLinks)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('add-link'),
                    onPressed: _addLink,
                    icon: const Icon(Icons.add_link, color: AppColors.lime),
                    label: const Text(
                      'Add link',
                      style: TextStyle(color: AppColors.lime),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              IgPrimaryButton(
                key: const ValueKey('edit-save'),
                label: 'Save',
                height: 44,
                loading: _saving,
                onPressed: _save,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _banner(UserProfile p) {
    return AspectRatio(
      aspectRatio: kBannerAspect,
      child: Material(
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(18),
        color: AppColors.surface,
        child: InkWell(
          key: const ValueKey('edit-banner'),
          onTap: () => _pick(cover: true),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (p.coverUrl.isEmpty)
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xFF1B1F6B), Color(0xFF2E3FD6)],
                    ),
                  ),
                )
              else
                NetImage(p.coverUrl),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.photo_camera_outlined, size: 16),
                      SizedBox(width: 6),
                      Text(
                        'Change banner',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _linkRow(int i) {
    final row = _links[i];
    return Padding(
      key: ObjectKey(row),
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              children: [
                IgTextField(
                  fieldKey: ValueKey('link-title-$i'),
                  height: 44,
                  hint: 'Title (e.g. YouTube)',
                  icon: Icons.title,
                  controller: row.title,
                  maxLength: ProfileLink.maxTitle,
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 6),
                IgTextField(
                  fieldKey: ValueKey('link-url-$i'),
                  height: 44,
                  hint: 'https://…',
                  icon: Icons.link,
                  controller: row.url,
                  maxLength: ProfileLink.maxUrl,
                  keyboardType: TextInputType.url,
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('link-remove-$i'),
            tooltip: 'Remove link',
            onPressed: () => _removeLink(i),
            icon: const Icon(Icons.close, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.only(left: 4, top: 6),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
    ),
  );

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 6),
    child: Text(
      text,
      style: const TextStyle(
        fontWeight: FontWeight.w600,
        fontSize: 13,
        color: AppColors.textSecondary,
      ),
    ),
  );
}
