import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';

/// v0.13: built-in sticker pack (`assets/stickers/ID.png`, work offline).
/// v0.14: 125 stickers, 35 of them animated (`ID.webp`), with search.
/// v0.16: 194 stickers, 69 of them animated.
///
/// A sticker is saved as the text `stk:ID` (video overlays and photo
/// layers). Its size is its WIDTH as a part of the frame width.
class StickerPack {
  StickerPack._();

  static const String prefix = 'stk:';

  /// Order shown in the editor (animated ones first).
  static const List<String> ids = [
    'a_heart',
    'a_fire',
    'a_haha',
    'a_yay',
    'a_wow',
    'a_wow_text',
    'a_omg',
    'a_omg_text',
    'a_lol',
    'a_lol_text',
    'a_star',
    'a_sparkle',
    'a_bolt',
    'a_crown',
    'a_hundred',
    'a_likes',
    'a_smiley',
    'a_sun',
    'a_music',
    'a_pin',
    'a_arrow',
    'a_check',
    'a_new',
    'a_boom',
    'a_pow',
    'a_hi',
    'a_rainbow',
    'a_cloud',
    'a_diya',
    'a_balloon',
    'a_kite',
    'a_gift',
    'a_cake',
    'a_party',
    'a_wah',
    // v0.16
    'a_rocket',
    'a_ghost',
    'a_cool',
    'a_laugh',
    'a_love_face',
    'a_sad',
    'a_happy',
    'a_ice_cream',
    'a_plane',
    'a_camera',
    'a_moon',
    'a_diamond',
    'a_flower',
    'a_pizza',
    'a_chai',
    'a_donut',
    'a_paw',
    'a_vibes',
    'a_miss_you',
    'a_congrats',
    'a_bday',
    'a_good_morning',
    'a_good_night',
    'a_epic',
    'a_pyaar',
    'a_lit_text',
    'a_slay_text',
    'a_yes_text',
    'a_bye_text',
    'a_woah_text',
    'a_hearts_up',
    'a_confetti',
    'a_zzz',
    'a_sparkles',
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
    'bindaas',
    'jhakaas',
    'mast',
    'sahi_hai',
    'arre_yaar',
    'pakka',
    'dhamaal',
    'kya_baat',
    'chalo',
    'full_on',
    'bhai',
    'yaar',
    'same',
    'mood',
    'goals',
    'brb',
    'idk',
    'nope',
    'haha',
    'slay',
    'lit',
    'facts',
    'oh_no',
    'aww',
    'yummy',
    'hi_wah',
    'hi_mast',
    'hi_diwali',
    'hi_dhanyavad',
    'hi_namaste',
    'diya',
    'chai',
    'kite',
    'balloon',
    'gift',
    'cake',
    'moon',
    'diamond',
    'flower',
    'pizza',
    // v0.16
    'party_time',
    'happy_bday',
    'yasss',
    'bestie',
    'ootd',
    'tbt',
    'lets_go',
    'ekdum_mast',
    'chill_maar',
    'jugaad',
    'filmy',
    'scene_hai',
    'paisa_vasool',
    'blessed_script',
    'love_you_script',
    'wanderlust_script',
    'cheers_script',
    'hi_pyaar',
    'hi_badhai',
    'hi_shubh_prabhat',
    'hi_holi',
    'cool_face',
    'laugh_face',
    'love_face',
    'sad_face',
    'happy_face',
    'ice_cream',
    'donut',
    'rocket',
    'ghost',
    'plane',
    'camera',
    'cricket',
    'paw',
    'mango',
  ];

  /// v0.14: animated stickers (`assets/stickers/ID.webp`, they move on
  /// videos and moments; a photo keeps the first frame).
  static bool isAnimated(String id) => id.startsWith('a_');

  /// v0.14: words for the sticker search.
  static const Map<String, String> tags = {
    'a_heart': 'heart love like beat',
    'a_fire': 'fire hot lit flame',
    'a_haha': 'haha lol funny laugh',
    'a_yay': 'yay happy party',
    'a_wow': 'wow amazing omg',
    'a_wow_text': 'wow amazing',
    'a_omg': 'omg shock',
    'a_omg_text': 'omg shock',
    'a_lol': 'lol funny laugh',
    'a_lol_text': 'lol funny laugh',
    'a_star': 'star shine',
    'a_sparkle': 'sparkle shine magic',
    'a_bolt': 'bolt lightning energy',
    'a_crown': 'crown king queen',
    'a_hundred': '100 hundred perfect',
    'a_likes': 'likes heart 1k',
    'a_smiley': 'smiley smile happy face',
    'a_sun': 'sun sunny morning summer',
    'a_music': 'music song note',
    'a_pin': 'pin location place',
    'a_arrow': 'arrow look here',
    'a_check': 'check done ok yes tick',
    'a_new': 'new badge',
    'a_boom': 'boom comic',
    'a_pow': 'pow comic',
    'a_hi': 'hi hello bubble',
    'a_rainbow': 'rainbow pride colors',
    'a_cloud': 'cloud chill relax',
    'a_diya': 'diya diwali lamp festival',
    'a_balloon': 'balloon birthday party',
    'a_kite': 'kite patang sankranti',
    'a_gift': 'gift present birthday',
    'a_cake': 'cake birthday',
    'a_party': 'party celebrate',
    'a_wah': 'wah wow hindi',
    'wow': 'wow amazing',
    'lol': 'lol funny laugh',
    'omg': 'omg shock',
    'yes': 'yes ok agree',
    'love_it': 'love it heart',
    'hello': 'hello hi',
    'thank_you': 'thank you thanks',
    'cool': 'cool nice',
    'heart': 'heart love',
    'fire': 'fire hot lit',
    'star': 'star',
    'sparkle': 'sparkle shine',
    'bolt': 'bolt lightning',
    'crown': 'crown king queen',
    'hundred': '100 hundred',
    'likes': 'likes heart 1k',
    'hello_script': 'hello hi',
    'love_script': 'love',
    'thanks_script': 'thanks thank you',
    'yay': 'yay happy',
    'cute': 'cute',
    'oops': 'oops sorry',
    'boom': 'boom comic',
    'pow': 'pow comic',
    'omg_wait': '?! wait what',
    'hi_bubble': 'hi hello',
    'smiley': 'smiley smile happy',
    'sun': 'sun sunny',
    'rainbow': 'rainbow',
    'chill_cloud': 'chill cloud relax',
    'music': 'music song',
    'pin': 'pin location',
    'arrow': 'arrow',
    'check': 'check done tick',
    'new_badge': 'new',
    'sale': 'sale offer',
    'no_way': 'no way',
    'bye': 'bye goodbye',
    'sorry': 'sorry',
    'epic': 'epic',
    'vibes': 'vibes',
    'good_morning': 'good morning',
    'good_night': 'good night',
    'happy_birthday': 'happy birthday bday',
    'congrats': 'congrats congratulations',
    'miss_you': 'miss you',
    'follow_me': 'follow me',
    'weekend': 'weekend',
    'party': 'party',
    'blessed': 'blessed',
    'bindaas': 'bindaas hinglish',
    'jhakaas': 'jhakaas hinglish awesome',
    'mast': 'mast hinglish great',
    'sahi_hai': 'sahi hai hinglish right',
    'arre_yaar': 'arre yaar hinglish',
    'pakka': 'pakka hinglish sure',
    'dhamaal': 'dhamaal hinglish fun',
    'kya_baat': 'kya baat hinglish wow',
    'chalo': 'chalo hinglish lets go',
    'full_on': 'full on hinglish',
    'bhai': 'bhai bro hinglish',
    'yaar': 'yaar friend hinglish',
    'same': 'same',
    'mood': 'mood',
    'goals': 'goals',
    'brb': 'brb be right back',
    'idk': 'idk dont know',
    'nope': 'nope no',
    'haha': 'haha lol funny',
    'slay': 'slay',
    'lit': 'lit fire',
    'facts': 'facts true',
    'oh_no': 'oh no',
    'aww': 'aww cute',
    'yummy': 'yummy food tasty',
    'hi_wah': 'wah hindi wow',
    'hi_mast': 'mast hindi',
    'hi_diwali': 'diwali deepavali hindi festival',
    'hi_dhanyavad': 'dhanyavad thanks hindi',
    'hi_namaste': 'namaste hello hindi',
    'diya': 'diya diwali lamp',
    'chai': 'chai tea cup',
    'kite': 'kite patang',
    'balloon': 'balloon party',
    'gift': 'gift present',
    'cake': 'cake birthday',
    'moon': 'moon night stars',
    'diamond': 'diamond gem',
    'flower': 'flower',
    'pizza': 'pizza food',
    // v0.16
    'party_time': 'party time fun celebrate',
    'happy_bday': 'happy birthday bday cake',
    'yasss': 'yass yes slay',
    'bestie': 'bestie best friend bff',
    'ootd': 'ootd outfit fashion',
    'tbt': 'tbt throwback memories',
    'lets_go': 'lets go yay',
    'ekdum_mast': 'ekdum mast hindi great',
    'chill_maar': 'chill maar relax hindi',
    'jugaad': 'jugaad hindi hack',
    'filmy': 'filmy bollywood movie',
    'scene_hai': 'scene hai hindi',
    'paisa_vasool': 'paisa vasool worth money hindi',
    'blessed_script': 'blessed grateful',
    'love_you_script': 'love you heart',
    'wanderlust_script': 'wanderlust travel trip',
    'cheers_script': 'cheers drink party',
    'hi_pyaar': 'pyaar love hindi',
    'hi_badhai': 'badhai congrats hindi',
    'hi_shubh_prabhat': 'shubh prabhat good morning hindi',
    'hi_holi': 'holi festival colours hindi',
    'cool_face': 'cool face sunglasses smiley',
    'laugh_face': 'laugh face lol haha crying smiley',
    'love_face': 'love face heart eyes smiley',
    'sad_face': 'sad face cry smiley',
    'happy_face': 'happy face smile smiley',
    'ice_cream': 'ice cream summer sweet',
    'donut': 'donut sweet food',
    'rocket': 'rocket launch space',
    'ghost': 'ghost boo halloween',
    'plane': 'plane travel flight trip',
    'camera': 'camera photo picture',
    'cricket': 'cricket bat ball sport',
    'paw': 'paw pet dog cat',
    'mango': 'mango fruit summer aam',
    'a_rocket': 'rocket launch space',
    'a_ghost': 'ghost boo halloween',
    'a_cool': 'cool face sunglasses smiley',
    'a_laugh': 'laugh lol haha face',
    'a_love_face': 'love heart eyes face',
    'a_sad': 'sad cry face',
    'a_happy': 'happy smile face',
    'a_ice_cream': 'ice cream summer',
    'a_plane': 'plane travel flight',
    'a_camera': 'camera photo',
    'a_moon': 'moon night stars',
    'a_diamond': 'diamond gem shine',
    'a_flower': 'flower spring',
    'a_pizza': 'pizza food',
    'a_chai': 'chai tea coffee',
    'a_donut': 'donut sweet',
    'a_paw': 'paw pet dog cat',
    'a_vibes': 'vibes mood',
    'a_miss_you': 'miss you love',
    'a_congrats': 'congrats well done',
    'a_bday': 'birthday bday cake',
    'a_good_morning': 'good morning gm',
    'a_good_night': 'good night gn sleep',
    'a_epic': 'epic awesome',
    'a_pyaar': 'pyaar love hindi',
    'a_lit_text': 'lit fire',
    'a_slay_text': 'slay queen',
    'a_yes_text': 'yes yess',
    'a_bye_text': 'bye goodbye',
    'a_woah_text': 'woah wow',
    'a_hearts_up': 'hearts love floating',
    'a_confetti': 'confetti party celebrate',
    'a_zzz': 'zzz sleep tired',
    'a_sparkles': 'sparkles shine magic',
  };

  /// Stickers that match [query] (empty = all). [animatedOnly] = only
  /// the moving ones.
  static List<String> search(String query, {bool animatedOnly = false}) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    return [
      for (final id in ids)
        if ((!animatedOnly || isAnimated(id)) &&
            words.every(
              (w) =>
                  (tags[id] ?? '').contains(w) ||
                  id.replaceAll('_', ' ').contains(w),
            ))
          id,
    ];
  }

  /// New sticker size (part of the frame width).
  static const double defaultSize = 0.45;
  static const double minSize = 0.08;
  static const double maxSize = 0.95;

  static String textFor(String id) => '$prefix$id';

  /// true for `stk:ID` (false for old emoji stickers).
  static bool isPack(String text) =>
      text.startsWith(prefix) && text.length > prefix.length;

  static String idOf(String text) => text.substring(prefix.length);

  static String assetFor(String text) {
    final id = isPack(text) ? idOf(text) : text;
    return 'assets/stickers/$id.${isAnimated(id) ? 'webp' : 'png'}';
  }

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

/// v0.15: the big sticker picker (search + 4 big stickers per row).
/// Returns the chosen sticker id.
class StickerSheet extends StatefulWidget {
  const StickerSheet({super.key});

  @override
  State<StickerSheet> createState() => _StickerSheetState();
}

class _StickerSheetState extends State<StickerSheet> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final found = StickerPack.search(_q);
    final h = MediaQuery.of(context).size.height;
    return SizedBox(
      height: h * 0.72,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: TextField(
              key: const ValueKey('sticker-search'),
              onChanged: (v) => setState(() => _q = v),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search stickers',
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: found.isEmpty
                ? const Center(
                    child: Text(
                      'No stickers found',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, box) {
                      final cell = (box.maxWidth - 24) / 4;
                      return GridView.builder(
                        key: const ValueKey('sticker-grid'),
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 4,
                              mainAxisSpacing: 6,
                              crossAxisSpacing: 6,
                            ),
                        itemCount: found.length,
                        itemBuilder: (context, i) => InkWell(
                          key: ValueKey('sticker-${found[i]}'),
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => Navigator.pop(context, found[i]),
                          child: Center(
                            child: StickerImage(
                              text: StickerPack.textFor(found[i]),
                              width: cell - 10,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
