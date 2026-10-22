import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/services/app_icon.dart';
import '../../../core/services/media_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../profile/presentation/profile_image_crop.dart';
import '../../../shared/widgets/skeleton.dart';

/// v0.15: Settings -> App icon.
class AppIconScreen extends StatefulWidget {
  const AppIconScreen({super.key});

  /// Tests: the picked (and cropped) picture.
  @visibleForTesting
  static Future<Uint8List?> Function()? debugPickPicture;

  @override
  State<AppIconScreen> createState() => _AppIconScreenState();
}

class _AppIconScreenState extends State<AppIconScreen> {
  String? _current;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    AppIcons.current().then((v) {
      if (mounted) setState(() => _current = v);
    });
  }

  Future<void> _pick(String id) async {
    if (_busy || id == _current) return;
    setState(() => _busy = true);
    final now = await AppIcons.set(id);
    if (!mounted) return;
    setState(() {
      _current = now;
      _busy = false;
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            now == id
                ? 'Icon changed. Your home screen may take a few seconds.'
                : 'Could not change the icon',
          ),
        ),
      );
  }

  // ---------------------------------------------- v0.16: your own picture

  Future<void> _custom() async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Your own icon'),
        content: const Text(
          'Pick a photo. InstantGram adds a new icon with your photo to '
          'your home screen.\n\nThe icon in your app list stays the same '
          '(Android does not let apps use any photo there).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('custom-icon-pick'),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Pick photo'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    Uint8List? bytes;
    try {
      if (AppIconScreen.debugPickPicture != null) {
        bytes = await AppIconScreen.debugPickPicture!();
      } else {
        final f = await MediaService.instance.pickGalleryImage();
        if (f == null || !mounted) return;
        final cropped = await cropProfileImage(
          context,
          f,
          ProfileImageSpec.photo,
        );
        if (cropped == null) return;
        bytes = await cropped.readAsBytes();
      }
    } catch (e) {
      _snack('Could not open your photos');
      return;
    }
    if (bytes == null || !mounted) return;
    setState(() => _busy = true);
    final png = await compute(AppIcons.customIconPng, bytes);
    final done = png != null && await AppIcons.pinCustom(png);
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(
      png == null
          ? 'Could not read this picture'
          : done
          ? 'Check your home screen. If your phone asks, tap Add.'
          : 'Your phone does not allow adding icons',
    );
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final cur = _current;
    return Scaffold(
      appBar: AppBar(title: const Text('App icon')),
      body: cur == null
          ? const Skeleton(count: 4)
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Pick how InstantGram looks on your home screen.',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 16),
                GridView.count(
                  crossAxisCount: 3,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  childAspectRatio: 0.82,
                  children: [
                    for (final e in AppIcons.all.entries)
                      _IconChoice(
                        key: ValueKey('app-icon-${e.key}'),
                        id: e.key,
                        label: e.value,
                        selected: e.key == cur,
                        onTap: () => _pick(e.key),
                      ),
                    // v0.16: your own picture (home-screen icon)
                    GestureDetector(
                      key: const ValueKey('app-icon-custom'),
                      onTap: _custom,
                      behavior: HitTestBehavior.opaque,
                      child: Column(
                        children: [
                          Container(
                            width: 76,
                            height: 76,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.surfaceHigh,
                              border: Border.all(color: AppColors.border),
                            ),
                            child: const Icon(
                              Icons.add_photo_alternate_outlined,
                              color: AppColors.lime,
                              size: 30,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Custom',
                            style: TextStyle(
                              fontWeight: FontWeight.w500,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Text(
                  'Some phones close the app for a moment when the icon '
                  'changes. Just open it again.\n\nCustom = a new icon with '
                  'your photo on your home screen. The app list icon stays '
                  'the same.',
                  style: TextStyle(color: AppColors.textHint, fontSize: 12.5),
                ),
              ],
            ),
    );
  }
}

class _IconChoice extends StatelessWidget {
  const _IconChoice({
    super.key,
    required this.id,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String id;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? AppColors.lime : Colors.transparent,
                width: 2.5,
              ),
            ),
            child: ClipOval(
              child: Image.asset(
                AppIcons.asset(id),
                width: 70,
                height: 70,
                fit: BoxFit.cover,
                errorBuilder: (context, e, s) => Container(
                  width: 70,
                  height: 70,
                  color: AppColors.surfaceHigh,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                const Icon(Icons.check_circle, size: 14, color: AppColors.lime),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
