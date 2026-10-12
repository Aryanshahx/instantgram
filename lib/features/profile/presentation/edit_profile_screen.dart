import 'package:flutter/material.dart';

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
        name: _name.text,
        bio: _bio.text,
        website: _website.text,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: ${friendlyError(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pick({required bool cover}) async {
    final file = await MediaService.instance.pick(
      context,
      maxWidth: cover ? 1600 : 800,
    );
    if (file == null || !mounted) return;
    await runWithProgress(
      context,
      title: cover ? 'Updating cover' : 'Updating photo',
      task: (p) => cover
          ? UserRepository.instance.changeCover(file, onProgress: p)
          : UserRepository.instance.changePhoto(file, onProgress: p),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: StreamBuilder<UserProfile?>(
        stream: UserRepository.instance.watchUser(widget.profile.uid),
        initialData: widget.profile,
        builder: (context, snap) {
          final p = snap.data ?? widget.profile;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              SizedBox(
                height: 150,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      bottom: 32,
                      child: GestureDetector(
                        onTap: () => _pick(cover: true),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (p.coverUrl.isEmpty)
                                const DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [
                                        Color(0xFF1B1F6B),
                                        Color(0xFF2E3FD6),
                                      ],
                                    ),
                                  ),
                                )
                              else
                                NetImage(p.coverUrl),
                              Container(
                                color: Colors.black38,
                                alignment: Alignment.center,
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.photo_camera_outlined, size: 18),
                                    SizedBox(width: 6),
                                    Text(
                                      'Change cover',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 16,
                      bottom: 0,
                      child: GestureDetector(
                        onTap: () => _pick(cover: false),
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(
                            color: AppColors.background,
                            shape: BoxShape.circle,
                          ),
                          child: Avatar(
                            url: p.photoUrl,
                            name: p.displayName,
                            size: 64,
                            showPlus: true,
                            onPlusTap: () => _pick(cover: false),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _label('Name'),
              IgTextField(
                height: 46,
                hint: 'Your name',
                icon: Icons.person_outline,
                controller: _name,
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 12),
              _label('Bio'),
              IgTextField(
                height: 46,
                hint: 'Tell people about yourself',
                controller: _bio,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 12),
              _label('Website'),
              IgTextField(
                height: 46,
                hint: 'https://your-site.com',
                icon: Icons.link,
                controller: _website,
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 20),
              IgPrimaryButton(
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
