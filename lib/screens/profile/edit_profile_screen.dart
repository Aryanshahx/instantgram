import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/responsive.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../services/media_service.dart';
import '../../services/user_service.dart';
import '../../widgets/avatar.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key, required this.user});
  final AppUser user;

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final _name = TextEditingController(text: widget.user.fullName);
  late final _bio = TextEditingController(text: widget.user.bio);
  File? _photo;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final f = await MediaService.pickAvatar(ImageSource.gallery);
      if (f != null && mounted) setState(() => _photo = f);
    } catch (_) {
      if (mounted) showToast(context, 'Could not open the gallery.');
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await UserService.instance.updateProfile(
        fullName: _name.text,
        bio: _bio.text,
        newPhoto: _photo,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: ContentWidth(
        maxWidth: 560,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          children: [
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
                            url: widget.user.photoUrl,
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
            const SizedBox(height: 28),
            TextField(
              controller: _name,
              enabled: !_saving,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _bio,
              enabled: !_saving,
              maxLength: 150,
              maxLines: 4,
              minLines: 3,
              decoration: const InputDecoration(labelText: 'Bio'),
            ),
            Text(
              'Username  @${widget.user.username}',
              style: TextStyle(color: context.muted),
            ),
            const SizedBox(height: 26),
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
