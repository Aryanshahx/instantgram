import 'package:flutter/material.dart';

import '../../../shared/models/user_profile.dart';
import '../../../shared/widgets/ig_buttons.dart';
import '../../../shared/widgets/ig_text_field.dart';
import '../data/user_repository.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key, required this.profile});

  final UserProfile profile;

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final _name = TextEditingController(text: widget.profile.name);
  late final _bio = TextEditingController(text: widget.profile.bio);
  late final _website = TextEditingController(text: widget.profile.website);
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    _website.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await UserRepository.instance.updateProfile(
        widget.profile.uid,
        name: _name.text,
        bio: _bio.text,
        website: _website.text,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _label('Name'),
          IgTextField(
            hint: 'Your name',
            icon: Icons.person_outline,
            controller: _name,
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 18),
          _label('Bio'),
          IgTextField(
            hint: 'Tell people about yourself',
            controller: _bio,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 18),
          _label('Website'),
          IgTextField(
            hint: 'https://your-site.com',
            icon: Icons.link,
            controller: _website,
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 28),
          IgPrimaryButton(label: 'Save', loading: _saving, onPressed: _save),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(left: 6, bottom: 8),
    child: Text(
      text,
      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
    ),
  );
}
