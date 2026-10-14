import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// v0.13: built-in sticker pack (`assets/stickers/ID.png`, work offline).
///
/// A sticker is saved as the text `stk:ID` (video overlays and photo
/// layers). Its size is its WIDTH as a part of the frame width.
class StickerPack {
  StickerPack._();

  static const String prefix = 'stk:';

  /// Order shown in the editor.
  static const List<String> ids = [
    'wow',
    'lol',
    'omg',
    'yes',
    'love_it',
    'hello',
    'thank_you',
    'cool',
    'heart',
    'fire',
    'star',
    'sparkle',
    'bolt',
    'crown',
    'hundred',
    'likes',
    'hello_script',
    'love_script',
    'thanks_script',
    'yay',
    'cute',
    'oops',
    'boom',
    'pow',
    'omg_wait',
    'hi_bubble',
    'smiley',
    'sun',
    'rainbow',
    'chill_cloud',
    'music',
    'pin',
    'arrow',
    'check',
    'new_badge',
    'sale',
    'no_way',
    'bye',
    'sorry',
    'epic',
    'vibes',
    'good_morning',
    'good_night',
    'happy_birthday',
    'congrats',
    'miss_you',
    'follow_me',
    'weekend',
    'party',
    'blessed',
  ];

  /// New sticker size (part of the frame width).
  static const double defaultSize = 0.32;
  static const double minSize = 0.08;
  static const double maxSize = 0.95;

  static String textFor(String id) => '$prefix$id';

  /// true for `stk:ID` (false for old emoji stickers).
  static bool isPack(String text) =>
      text.startsWith(prefix) && text.length > prefix.length;

  static String idOf(String text) => text.substring(prefix.length);

  static String assetFor(String text) =>
      'assets/stickers/${isPack(text) ? idOf(text) : text}.png';

  /// For drawing into a saved photo.
  static Future<ui.Image?> load(String text) async {
    try {
      final data = await rootBundle.load(assetFor(text));
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (e) {
      debugPrint('sticker $text: $e');
      return null;
    }
  }
}

/// A pack sticker [width] pixels wide.
class StickerImage extends StatelessWidget {
  const StickerImage({super.key, required this.text, required this.width});
  final String text;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      StickerPack.assetFor(text),
      width: width,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      errorBuilder: (c, e, s) => SizedBox(width: width, height: width * 0.5),
    );
  }
}
