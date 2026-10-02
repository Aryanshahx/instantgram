import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/errors.dart';
import '../../core/ui.dart';
import '../../models/app_user.dart';
import '../../services/storage_service.dart';
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
      appBar: AppBar(
        title: const Text('Edit profile',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Done',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: GestureDetector(
              onTap: _saving ? null : _pickPhoto,
              child: Column(
                children: [
                  _photo != null
                      ? CircleAvatar(
                          radius: 52, backgroundImage: FileImage(_photo!))
                      : UserAvatar(url: widget.user.photoUrl, radius: 52),
                  const SizedBox(height: 10),
                  const Text('Change profile photo',
                      style: TextStyle(
                          color: Color(0xFF0095F6),
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _name,
            enabled: !_saving,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _bio,
            enabled: !_saving,
            maxLength: 150,
            maxLines: 4,
            minLines: 2,
            decoration: const InputDecoration(labelText: 'Bio'),
          ),
          const SizedBox(height: 8),
          Text('Username: @${widget.user.username}',
              style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}
