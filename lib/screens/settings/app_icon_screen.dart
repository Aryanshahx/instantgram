import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/app_icon_service.dart';
import '../../services/custom_icon.dart';

/// Tests: replaces the photo picker of the custom icon (returns the picture's bytes).
Future<Uint8List?> Function()? debugPickIconPhoto;

/// Settings > App icon: pick how InstantGram looks on the home screen.
class AppIconScreen extends StatefulWidget {
  const AppIconScreen({super.key});

  @override
  State<AppIconScreen> createState() => _AppIconScreenState();
}

class _AppIconScreenState extends State<AppIconScreen> {
  bool? _available;
  String _current = 'classic';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = AppIconService.instance;
    final ok = await s.available();
    final cur = ok ? await s.current() : 'classic';
    if (mounted) {
      setState(() {
        _available = ok;
        _current = cur;
      });
    }
  }

  Future<void> _pick(AppIconOption o) async {
    if (_busy || o.id == _current) return;
    setState(() => _busy = true);
    try {
      await AppIconService.instance.set(o.id);
      if (!mounted) return;
      setState(() => _current = o.id);
      showToast(
        context,
        'Icon changed to ${o.label}. Your home screen may take a few seconds.',
      );
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Uint8List?
  _custom; // the 512 x 512 picture, before it is put on the home screen

  Future<void> _chooseCustom() async {
    try {
      final pick = debugPickIconPhoto;
      Uint8List? bytes;
      if (pick != null) {
        bytes = await pick();
      } else {
        final x = await ImagePicker().pickImage(source: ImageSource.gallery);
        bytes = await x?.readAsBytes();
      }
      if (bytes == null) return;
      final sq = await squareIcon(bytes);
      if (mounted) setState(() => _custom = sq);
    } catch (_) {
      if (mounted) showToast(context, 'That picture could not be used.');
    }
  }

  Future<void> _addCustom() async {
    final sq = _custom;
    if (sq == null || _busy) return;
    setState(() => _busy = true);
    try {
      final r = await AppIconService.instance.pinCustom(await adaptiveIcon(sq));
      if (!mounted) return;
      showToast(context, switch (r) {
        'pinned' => 'Tap "Add" to put your icon on the home screen.',
        'updated' => 'Your home-screen icon got the new picture.',
        _ => 'This phone cannot add custom icons.',
      });
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _round(Widget child, {bool on = false}) => AspectRatio(
    aspectRatio: 1,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: on ? AppTheme.volt : Colors.transparent,
          width: 3,
        ),
      ),
      child: ClipOval(child: child),
    ),
  );

  Widget _customSection(BuildContext context) {
    final img = _custom;
    return Container(
      key: const ValueKey('customIconCard'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.card,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: _round(
              img == null
                  ? ColoredBox(
                      color: context.muted.withValues(alpha: 0.15),
                      child: const Icon(Icons.add_photo_alternate_outlined),
                    )
                  : Image.memory(
                      img,
                      key: const ValueKey('customIconPreview'),
                      fit: BoxFit.cover,
                    ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Your own icon',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  'Any photo, cut square to $kCustomIconSize × $kCustomIconSize. '
                  'It is added to your home screen as an InstantGram icon.',
                  style: TextStyle(color: context.muted, fontSize: 12.5),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    OutlinedButton(
                      key: const ValueKey('customIconPick'),
                      onPressed: _busy ? null : _chooseCustom,
                      child: Text(img == null ? 'Choose photo' : 'Change'),
                    ),
                    if (img != null)
                      FilledButton(
                        key: const ValueKey('customIconAdd'),
                        onPressed: _busy ? null : _addCustom,
                        child: const Text('Add to home screen'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ok = _available;
    return Scaffold(
      appBar: AppBar(title: const Text('App icon')),
      body: ok == null
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  ok
                      ? 'Choose how InstantGram looks on your home screen.'
                      : 'Changing the icon needs the newest app build. '
                            'Install the latest APK and try again.',
                  style: TextStyle(color: context.muted),
                ),
                const SizedBox(height: 16),
                GridView.count(
                  crossAxisCount: MediaQuery.sizeOf(context).width > 600
                      ? 6
                      : 3,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  childAspectRatio: 0.82,
                  children: [
                    for (final o in kAppIcons)
                      GestureDetector(
                        key: ValueKey('icon_${o.id}'),
                        onTap: ok ? () => _pick(o) : null,
                        child: Opacity(
                          opacity: ok ? 1 : 0.5,
                          child: Column(
                            children: [
                              Expanded(
                                child: Center(
                                  child: _round(
                                    Image.asset(
                                      o.asset,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => const Icon(
                                        Icons.apps_rounded,
                                        size: 40,
                                      ),
                                    ),
                                    on: o.id == _current,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (o.id == _current) ...[
                                    const Icon(
                                      Icons.check_circle_rounded,
                                      size: 15,
                                      color: AppTheme.volt,
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Flexible(
                                    child: Text(
                                      o.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                _customSection(context),
              ],
            ),
    );
  }
}
