import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/errors.dart';
import '../../core/fonts.dart';
import '../../core/media_url.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../services/image_check.dart';
import '../../services/media_service.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/font_picker.dart';

/// Turns what the user typed into a link that can be opened (adds https:// when missing).
/// Returns null when it is not a usable web address.
String? normalizeLink(String input) {
  var t = input.trim();
  if (t.isEmpty) return null;
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(t)) t = 'https://$t';
  final u = Uri.tryParse(t);
  if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) return null;
  if (u.host.isEmpty || !u.host.contains('.') || t.contains(' ')) return null;
  return t;
}

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key, required this.user});
  final AppUser user;

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final _name = TextEditingController(text: widget.user.fullName);
  late final _username = TextEditingController(text: widget.user.username);
  late final _bio = TextEditingController(text: widget.user.bio);
  late String _bioFont = widget.user.bioFont;
  late final List<TextEditingController> _links = [
    for (var i = 0; i < 3; i++)
      TextEditingController(
        text: i < widget.user.links.length ? widget.user.links[i] : '',
      ),
  ];
  late final List<TextEditingController> _linkNames = [
    for (var i = 0; i < 3; i++)
      TextEditingController(text: widget.user.linkLabel(i)),
  ];
  File? _photo;
  File? _banner;
  bool _removePhoto = false;
  bool _removeBanner = false;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _bio.dispose();
    for (final c in _links) {
      c.dispose();
    }
    for (final c in _linkNames) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _hasPhoto =>
      _photo != null || (!_removePhoto && widget.user.photoUrl.isNotEmpty);
  bool get _hasBanner =>
      _banner != null || (!_removeBanner && widget.user.bannerUrl.isNotEmpty);

  Future<void> _pickPhoto() async {
    try {
      final f = await MediaService.pickAvatar(ImageSource.gallery);
      if (f == null || !mounted) return;
      // nudity is not allowed here (checked on the phone)
      await ImageCheck.instance.checkAvatar(f, what: 'profile photo');
      if (!mounted) return;
      setState(() {
        _photo = f;
        _removePhoto = false;
      });
    } on ModerationException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not open the gallery.');
    }
  }

  Future<void> _pickBanner() async {
    try {
      final f = await MediaService.pickBanner(ImageSource.gallery);
      if (f == null || !mounted) return;
      // nudity is not allowed here (checked on the phone)
      await ImageCheck.instance.checkAvatar(f, what: 'cover photo');
      if (!mounted) return;
      setState(() {
        _banner = f;
        _removeBanner = false;
      });
    } on ModerationException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, 'Could not open the gallery.');
    }
  }

  Future<void> _save() async {
    final uname = _username.text.trim().toLowerCase();
    if (!UserService.usernameRegex.hasMatch(uname)) {
      showToast(
        context,
        'Username: 3-20 characters, only a-z, 0-9, dot and underscore.',
      );
      return;
    }
    final links = <String>[];
    final names = <String>[];
    for (var i = 0; i < _links.length; i++) {
      final c = _links[i];
      if (c.text.trim().isEmpty) continue;
      final l = normalizeLink(c.text);
      if (l == null) {
        showToast(context, '"${c.text.trim()}" is not a valid link.');
        return;
      }
      links.add(l);
      names.add(_linkNames[i].text.trim());
    }
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    try {
      await UserService.instance.updateProfile(
        fullName: _name.text,
        bio: _bio.text,
        bioFont: _bioFont,
        newPhoto: _photo,
        removePhoto: _removePhoto && _photo == null,
        newBanner: _banner,
        removeBanner: _removeBanner && _banner == null,
        username: uname,
        links: links,
        linkNames: names,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _bannerPreview(BuildContext context) {
    Widget child;
    if (_banner != null) {
      child = Image.file(_banner!, fit: BoxFit.cover);
    } else if (_hasBanner) {
      child = CachedNetworkImage(
        imageUrl: resolveMediaUrl(widget.user.bannerUrl),
        fit: BoxFit.cover,
        errorWidget: (_, _, _) => const DecoratedBox(
          decoration: BoxDecoration(gradient: AppTheme.auroraGradient),
        ),
      );
    } else {
      child = const DecoratedBox(
        decoration: BoxDecoration(gradient: AppTheme.auroraGradient),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: SizedBox(
        height: 140,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            Positioned(
              right: 10,
              bottom: 10,
              child: Row(
                children: [
                  if (_hasBanner)
                    _chip(
                      icon: Icons.delete_outline_rounded,
                      label: 'Remove',
                      onTap: _saving
                          ? null
                          : () => setState(() {
                              _banner = null;
                              _removeBanner = true;
                            }),
                    ),
                  const SizedBox(width: 8),
                  _chip(
                    icon: Icons.image_outlined,
                    label: _hasBanner ? 'Change banner' : 'Add banner',
                    onTap: _saving ? null : _pickBanner,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.white),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: ContentWidth(
        maxWidth: 560,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            _bannerPreview(context),
            const SizedBox(height: 18),
            Center(
              child: GestureDetector(
                onTap: _saving ? null : _pickPhoto,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _photo != null
                        ? ClipOval(
                            child: Image.file(
                              _photo!,
                              width: 104,
                              height: 104,
                              fit: BoxFit.cover,
                            ),
                          )
                        : UserAvatar(
                            url: _removePhoto ? '' : widget.user.photoUrl,
                            name: widget.user.username,
                            radius: 52,
                          ),
                    Positioned(
                      right: -6,
                      bottom: -6,
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: AppTheme.volt,
                          shape: BoxShape.circle,
                          border: Border.all(color: context.bg, width: 3),
                        ),
                        child: const Icon(
                          Icons.photo_camera_rounded,
                          size: 18,
                          color: AppTheme.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_hasPhoto)
              Center(
                child: TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                          _photo = null;
                          _removePhoto = true;
                        }),
                  child: const Text('Use the default picture'),
                ),
              )
            else
              const SizedBox(height: 14),
            _section(context, 'About you'),
            TextField(
              controller: _name,
              enabled: !_saving,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _username,
              enabled: !_saving,
              autocorrect: false,
              enableSuggestions: false,
              maxLength: 20,
              decoration: const InputDecoration(
                labelText: 'Username',
                prefixText: '@',
                helperText: 'a-z, 0-9, dot and underscore',
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _bio,
              enabled: !_saving,
              maxLength: 150,
              maxLines: 4,
              minLines: 3,
              style: maybeAppFont(_bioFont, const TextStyle(fontSize: 16)),
              decoration: const InputDecoration(labelText: 'Bio'),
            ),
            Text(
              'Bio font (everyone sees it)',
              style: TextStyle(color: context.muted, fontSize: 12),
            ),
            FontChipRow(
              keyPrefix: 'bioFont',
              selected: _bioFont,
              enabled: !_saving,
              onChanged: (f) => setState(() => _bioFont = f),
            ),
            _section(context, 'Links'),
            for (var i = 0; i < _links.length; i++) ...[
              TextField(
                key: ValueKey('linkName$i'),
                controller: _linkNames[i],
                enabled: !_saving,
                maxLength: 24,
                buildCounter:
                    (
                      _, {
                      required currentLength,
                      required isFocused,
                      maxLength,
                    }) => null,
                decoration: InputDecoration(
                  labelText: 'Link ${i + 1} name',
                  hintText: 'My shop, Portfolio, YouTube...',
                  prefixIcon: const Icon(Icons.label_outline_rounded),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _links[i],
                enabled: !_saving,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Link ${i + 1} address',
                  hintText: 'https://',
                  prefixIcon: const Icon(Icons.link_rounded),
                ),
              ),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 14),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: AppTheme.ink,
                      ),
                    )
                  : const Text('Save changes'),
            ),
          ],
        ),
      ),
    );
  }
}
