import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/services/chat_prefs.dart';
import '../../core/theme/app_colors.dart';

/// v0.0.1: chat themes (background + bubble colours). Only YOU see the
/// theme you pick for a chat; it is saved in prefs/{uid}.chatThemes.
@immutable
class ChatTheme {
  const ChatTheme({
    required this.id,
    required this.name,
    required this.bgTop,
    required this.bgBottom,
    required this.mine,
    this.mine2,
    required this.mineText,
    required this.other,
    this.otherText = AppColors.textPrimary,
  });

  final String id;
  final String name;

  /// Chat background (top -> bottom).
  final Color bgTop;
  final Color bgBottom;

  /// Your bubbles ([mine2] = second colour of a gradient).
  final Color mine;
  final Color? mine2;
  final Color mineText;

  /// Their bubbles.
  final Color other;
  final Color otherText;

  /// Light text on your bubble -> light ticks / quote colours.
  bool get mineDark => mineText.computeLuminance() > 0.5;

  /// Small text on your bubble (time, "Forwarded").
  Color get mineSub => mineText.withValues(alpha: 0.54);

  /// Your bubble: colour or gradient.
  BoxDecoration mineBubble(BorderRadius radius) => BoxDecoration(
    color: mine2 == null ? mine : null,
    gradient: mine2 == null
        ? null
        : LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [mine, mine2!],
          ),
    borderRadius: radius,
  );

  /// Chat background (plain when both colours are the same).
  BoxDecoration get background => bgTop == bgBottom
      ? BoxDecoration(color: bgTop)
      : BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [bgTop, bgBottom],
          ),
        );

  static const String defaultId = 'lime';

  static const ChatTheme lime = ChatTheme(
    id: 'lime',
    name: 'Lime',
    bgTop: AppColors.background,
    bgBottom: AppColors.background,
    mine: AppColors.lime,
    mineText: Colors.black,
    other: AppColors.surface,
  );

  static const List<ChatTheme> all = [
    lime,
    ChatTheme(
      id: 'ocean',
      name: 'Ocean',
      bgTop: Color(0xFF04161F),
      bgBottom: Color(0xFF0A2A3A),
      mine: Color(0xFF2DD4BF),
      mineText: Colors.black,
      other: Color(0xFF12303D),
    ),
    ChatTheme(
      id: 'grape',
      name: 'Grape',
      bgTop: Color(0xFF140A24),
      bgBottom: Color(0xFF24123F),
      mine: Color(0xFF7C3AED),
      mine2: Color(0xFFA855F7),
      mineText: Colors.white,
      other: Color(0xFF2A1C45),
    ),
    ChatTheme(
      id: 'sunset',
      name: 'Sunset',
      bgTop: Color(0xFF1F0B0B),
      bgBottom: Color(0xFF2E1220),
      mine: Color(0xFFE0532E),
      mine2: Color(0xFFD9285F),
      mineText: Colors.white,
      other: Color(0xFF3A1A24),
    ),
    ChatTheme(
      id: 'rose',
      name: 'Rose',
      bgTop: Color(0xFF1A0A12),
      bgBottom: Color(0xFF2A0F1F),
      mine: Color(0xFFF9A8D4),
      mineText: Colors.black,
      other: Color(0xFF3A1A2A),
    ),
    ChatTheme(
      id: 'forest',
      name: 'Forest',
      bgTop: Color(0xFF06140C),
      bgBottom: Color(0xFF0E2418),
      mine: Color(0xFF4ADE80),
      mineText: Colors.black,
      other: Color(0xFF173323),
    ),
    ChatTheme(
      id: 'gold',
      name: 'Gold',
      bgTop: Color(0xFF17120A),
      bgBottom: Color(0xFF241B0D),
      mine: Color(0xFFFBBF24),
      mineText: Colors.black,
      other: Color(0xFF33281A),
    ),
    ChatTheme(
      id: 'sky',
      name: 'Sky',
      bgTop: Color(0xFF06121F),
      bgBottom: Color(0xFF0C1E33),
      mine: Color(0xFF7DD3FC),
      mineText: Colors.black,
      other: Color(0xFF15283D),
    ),
    ChatTheme(
      id: 'cherry',
      name: 'Cherry',
      bgTop: Color(0xFF1A0505),
      bgBottom: Color(0xFF2A0A0A),
      mine: Color(0xFFDC2626),
      mine2: Color(0xFFEF4444),
      mineText: Colors.white,
      other: Color(0xFF3A1515),
    ),
    ChatTheme(
      id: 'mono',
      name: 'Mono',
      bgTop: Colors.black,
      bgBottom: Colors.black,
      mine: Colors.white,
      mineText: Colors.black,
      other: Color(0xFF1E1E1E),
    ),
  ];

  /// Unknown / empty id -> Lime.
  static ChatTheme byId(String? id) {
    for (final t in all) {
      if (t.id == id) return t;
    }
    return lime;
  }

  /// The theme above in the widget tree (Lime when there is none).
  static ChatTheme of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatThemeScope>()?.theme ??
      lime;
}

/// Gives [ChatTheme.of] to the message widgets below it.
class ChatThemeScope extends InheritedWidget {
  const ChatThemeScope({super.key, required this.theme, required super.child});

  final ChatTheme theme;

  @override
  bool updateShouldNotify(ChatThemeScope oldWidget) =>
      oldWidget.theme.id != theme.id;
}

/// Chat background: the theme colours, and your photo on top (a bit
/// darker so the messages stay easy to read). Only you see it.
class ChatBackground extends StatelessWidget {
  const ChatBackground({super.key, required this.theme, this.photo = ''});

  final ChatTheme theme;

  /// Picture file on this phone ('' = none).
  final String photo;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: ValueKey('chat-bg-${theme.id}'),
      decoration: theme.background,
      child: photo.isEmpty
          ? const SizedBox.expand()
          : Stack(
              fit: StackFit.expand,
              children: [
                Image.file(
                  File(photo),
                  key: const ValueKey('chat-bg-photo'),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  // file gone (phone cleaned) -> just the theme
                  errorBuilder: (context, error, stack) =>
                      const SizedBox.shrink(),
                ),
                const ColoredBox(color: Color(0x66000000)),
              ],
            ),
    );
  }
}

/// Picks a photo from the gallery and keeps a copy for this chat
/// (null = cancelled).
Future<String?> pickChatBackground(String chatId) async {
  final x = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: 1600,
    maxHeight: 1600,
    imageQuality: 85,
  );
  if (x == null) return null;
  final dir = Directory(
    '${(await getApplicationDocumentsDirectory()).path}/chat_bg',
  );
  await dir.create(recursive: true);
  final safe = chatId.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  final out = File(
    '${dir.path}/${safe}_${DateTime.now().millisecondsSinceEpoch}.jpg',
  );
  await File(x.path).copy(out.path);
  return out.path;
}

/// "Chat theme" sheet: colours + background photo. Returns the picked
/// theme id (also saved) or null.
Future<String?> showChatThemePicker(
  BuildContext context,
  String chatId, {
  Future<void> Function(String chatId, String themeId)? save,
  Future<String?> Function(String chatId)? pickPhoto,
  Future<void> Function(String chatId, String? path)? saveBackground,
}) async {
  final prefs = ChatPrefs.instance.value.value;
  final now = prefs.themeOf(chatId);
  final hasPhoto = prefs.backgroundOf(chatId).isNotEmpty;
  final picked = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    builder: (ctx) => SafeArea(
      // scrolls on small screens (themes + background)
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Chat theme',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              const Text(
                'Only you see it',
                style: TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final t in ChatTheme.all)
                    _Swatch(
                      theme: t,
                      selected: t.id == now,
                      onTap: () => Navigator.of(ctx).pop(t.id),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Background',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('chat-bg-pick'),
                      onPressed: () => Navigator.of(ctx).pop(_photoPick),
                      icon: const Icon(Icons.image_outlined, size: 18),
                      label: Text(hasPhoto ? 'Change photo' : 'Choose photo'),
                    ),
                  ),
                  if (hasPhoto) ...[
                    const SizedBox(width: 10),
                    OutlinedButton(
                      key: const ValueKey('chat-bg-remove'),
                      onPressed: () => Navigator.of(ctx).pop(_photoRemove),
                      child: const Text(
                        'Remove',
                        style: TextStyle(color: AppColors.like),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (picked == null) return null;
  final setBg = saveBackground ?? ChatPrefs.instance.setBackground;
  if (picked == _photoRemove) {
    await setBg(chatId, null);
    return null;
  }
  if (picked == _photoPick) {
    try {
      final path = await (pickPhoto ?? pickChatBackground)(chatId);
      if (path != null) await setBg(chatId, path);
    } catch (e) {
      debugPrint('chat background: $e');
    }
    return null;
  }
  if (picked == now) return picked;
  await (save ?? ChatPrefs.instance.setTheme)(chatId, picked);
  return picked;
}

const String _photoPick = '#photo';
const String _photoRemove = '#remove';

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  final ChatTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    Widget bubble(bool mine, double w) => Container(
      width: w,
      height: 11,
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: mine
          ? t.mineBubble(BorderRadius.circular(6))
          : BoxDecoration(
              color: t.other,
              borderRadius: BorderRadius.circular(6),
            ),
    );
    return GestureDetector(
      key: ValueKey('chat-theme-${t.id}'),
      onTap: onTap,
      child: SizedBox(
        width: 62,
        child: Column(
          children: [
            Container(
              width: 58,
              height: 66,
              padding: const EdgeInsets.all(7),
              decoration: t.background.copyWith(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected ? AppColors.lime : AppColors.border,
                  width: selected ? 2 : 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: bubble(false, 28),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: bubble(true, 30),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: bubble(false, 20),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              t.name,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                color: selected
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
