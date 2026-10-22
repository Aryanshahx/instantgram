import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_colors.dart';

/// Emoji groups for the "+" picker (reactions).
const List<(String, IconData, String)> kEmojiGroups = [
  (
    'Smileys',
    Icons.emoji_emotions_outlined,
    '😀😃😄😁😆😅🤣😂🙂🙃😉😊😇🥰😍🤩😘😗😚😙🥲😋😛😜🤪😝🤑🤗🤭🤫🤔🤐🤨😐😑😶😏😒🙄😬😮‍💨🤥😌😔😪🤤😴😷🤒🤕🤢🤮🥵🥶🥴😵🤯🤠🥳🥸😎🤓🧐😕😟🙁☹️😮😯😲😳🥺😦😧😨😰😥😢😭😱😖😣😞😓😩😫🥱😤😡😠🤬😈👿💀☠️💩🤡👹👺👻👽👾🤖😺😸😹😻😼😽🙀😿😾🙈🙉🙊',
  ),
  (
    'Gestures',
    Icons.back_hand_outlined,
    '👋🤚🖐️✋🖖👌🤌🤏✌️🤞🤟🤘🤙👈👉👆🖕👇☝️👍👎✊👊🤛🤜👏🙌👐🤲🤝🙏✍️💅🤳💪🦾🦵🦶👂🦻👃🧠🫀🫁🦷🦴👀👁️👅👄💋',
  ),
  (
    'Hearts',
    Icons.favorite_border,
    '❤️🧡💛💚💙💜🖤🤍🤎💔❣️💕💞💓💗💖💘💝💟❤️‍🔥❤️‍🩹♥️💌💯💢💥💫💦💨🕳️💬👁️‍🗨️🗨️🗯️💭💤',
  ),
  (
    'Animals',
    Icons.pets,
    '🐶🐱🐭🐹🐰🦊🐻🐼🐨🐯🦁🐮🐷🐸🐵🐔🐧🐦🐤🦆🦅🦉🦇🐺🐗🐴🦄🐝🐛🦋🐌🐞🐜🦟🐢🐍🦎🐙🦑🦐🦀🐡🐠🐟🐬🐳🐋🦈🐊🐅🐆🦓🦍🐘🦛🦏🐪🦒🦘🐃🐄🐎🐖🐏🐑🦙🐐🦌🐕🐩🐈🐓🦃🦚🦜🦢🕊️🐇🦝🦨🦡🦦🦥🐁🐀🐿️🦔🌵🎄🌲🌳🌴🌱🌿☘️🍀🍃🍂🍁🍄🌾💐🌷🌹🥀🌺🌸🌼🌻🌞🌝🌛🌜🌚🌕🌙🌎⭐🌟✨⚡🔥🌈☀️⛅☁️🌧️⛈️❄️☃️⛄🌊💧',
  ),
  (
    'Food',
    Icons.restaurant_outlined,
    '🍏🍎🍐🍊🍋🍌🍉🍇🍓🫐🍈🍒🍑🥭🍍🥥🥝🍅🍆🥑🥦🥬🥒🌶️🌽🥕🧄🧅🥔🍠🥐🥯🍞🥖🧀🥚🍳🧈🥞🧇🥓🥩🍗🍖🌭🍔🍟🍕🥪🌮🌯🥗🥘🍝🍜🍲🍛🍣🍱🥟🍤🍙🍚🍘🍥🥮🍢🍡🍧🍨🍦🥧🧁🍰🎂🍮🍭🍬🍫🍿🍩🍪🌰🥜🍯🥛☕🍵🧃🥤🧋🍶🍺🍻🥂🍷🥃🍸🍹🧉🍾🧊',
  ),
  (
    'Activities',
    Icons.sports_soccer,
    '⚽🏀🏈⚾🥎🎾🏐🏉🥏🎱🏓🏸🏒🏑🥍🏏🥅⛳🏹🎣🥊🥋🎽🛹🛼⛸️🥌🎿⛷️🏂🏋️🤸⛹️🤺🤾🏌️🏇🧘🏄🏊🤽🚣🧗🚴🏆🥇🥈🥉🏅🎖️🎗️🎫🎟️🎪🤹🎭🎨🎬🎤🎧🎼🎹🥁🎷🎺🎸🪕🎻🎲♟️🎯🎳🎮🎰🧩',
  ),
  (
    'Travel',
    Icons.flight_outlined,
    '🚗🚕🚙🚌🚎🏎️🚓🚑🚒🚐🛻🚚🚛🚜🛵🏍️🛺🚲🛴🚨🚔🚍🚘🚖🚡🚠🚟🚃🚋🚞🚝🚄🚅🚈🚂🚆🚇🚊🚉✈️🛫🛬🛩️💺🛰️🚀🛸🚁🛶⛵🚤🛥️🛳️⛴️🚢⚓⛽🚧🚦🚥🗺️🗿🗽🗼🏰🏯🏟️🎡🎢🎠⛲⛱️🏖️🏝️🏜️🌋⛰️🏔️🗻🏕️⛺🏠🏡🏘️🏗️🏭🏢🏬🏣🏤🏥🏦🏨🏪🏫🏩💒🏛️⛪🕌🛕🕍🕋⛩️🌅🌄🌠🎇🎆🌇🌆🏙️🌃🌌🌉🌁',
  ),
  (
    'Objects',
    Icons.lightbulb_outline,
    '⌚📱💻⌨️🖥️🖨️🖱️💽💾💿📀📷📸📹🎥📞☎️📺📻🎙️⏰⌛⏳📡🔋🔌💡🔦🕯️💸💵💴💶💷💰💳💎⚖️🔧🔨⚒️🛠️⛏️🔩⚙️🧱⛓️🧲🔫💣🧨🪓🔪🗡️⚔️🛡️🚬⚰️🔮📿🧿💈⚗️🔭🔬💊💉🩸🧬🦠🧫🧪🌡️🧹🧺🧻🚽🚰🚿🛁🧼🪥🧽🧴🛎️🔑🗝️🚪🪑🛋️🛏️🧸🖼️🛍️🛒🎁🎈🎏🎀🎊🎉🎎🏮🎐🧧✉️📩📨📧💌📥📤📦🏷️📪📫📬📭📮📜📃📄📑📊📈📉🗒️🗓️📆📅🗑️📇🗃️🗳️🗄️📋📁📂🗂️🗞️📰📓📔📒📕📗📘📙📚📖🔖🧷🔗📎🖇️📐📏🧮📌📍✂️🖊️🖋️✒️🖌️🖍️📝✏️🔍🔎🔏🔐🔒🔓',
  ),
  (
    'Symbols',
    Icons.emoji_symbols_outlined,
    '☮️✝️☪️🕉️☸️✡️🔯🕎☯️☦️🛐⛎♈♉♊♋♌♍♎♏♐♑♒♓🆔⚛️🉑☢️☣️📴📳🈶🈚🈸🈺🈷️✴️🆚💮🉐㊙️㊗️🈴🈵🈹🈲🅰️🅱️🆎🆑🅾️🆘❌⭕🛑⛔📛🚫💯💢♨️🚷🚯🚳🚱🔞📵🚭❗❕❓❔‼️⁉️🔅🔆〽️⚠️🚸🔱⚜️🔰♻️✅🈯💹❇️✳️❎🌐💠Ⓜ️🌀💤🏧🚾♿🅿️🈳🈂️🛂🛃🛄🛅🚹🚺🚼🚻🚮🎦📶🈁🔣ℹ️🔤🔡🔠🆖🆗🆙🆒🆕🆓0️⃣1️⃣2️⃣3️⃣4️⃣5️⃣6️⃣7️⃣8️⃣9️⃣🔟🔢#️⃣*️⃣▶️⏸️⏯️⏹️⏺️⏭️⏮️⏩⏪⏫⏬◀️🔼🔽➡️⬅️⬆️⬇️↗️↘️↙️↖️↕️↔️↪️↩️⤴️⤵️🔀🔁🔂🔄🔃🎵🎶➕➖➗✖️♾️💲💱™️©️®️〰️➰➿🔚🔙🔛🔝🔜✔️☑️🔘🔴🟠🟡🟢🔵🟣⚫⚪🟤🔺🔻🔸🔹🔶🔷🔳🔲▪️▫️◾◽◼️◻️🟥🟧🟨🟩🟦🟪⬛⬜🟫🔈🔇🔉🔊🔔🔕📣📢🏳️🏴🏁🚩🏳️‍🌈🇮🇳',
  ),
];

/// All emojis of a group (one per grapheme).
List<String> emojisOf(String group) => group.characters.toList();

/// Your quick reactions (the row on a long-press) and recent emojis.
/// Saved on this phone.
class QuickReactions {
  QuickReactions._();
  static final QuickReactions instance = QuickReactions._();

  static const List<String> defaults = ['❤️', '😂', '😮', '😢', '😡', '👍'];
  static const int maxRecent = 24;
  static const String _kQuick = 'react_quick';
  static const String _kRecent = 'emoji_recent';

  final ValueNotifier<List<String>> emojis = ValueNotifier(defaults);
  final ValueNotifier<List<String>> recent = ValueNotifier(const []);
  bool _loaded = false;

  /// Loads once (fast, cached); errors -> defaults.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      emojis.value = cleanQuick(_list(p.getString(_kQuick)));
      recent.value = _list(
        p.getString(_kRecent),
      ).where(validEmoji).take(maxRecent).toList();
    } catch (e) {
      debugPrint('quick reactions: $e');
    }
  }

  static List<String> _list(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final v = jsonDecode(raw);
      if (v is List) return v.whereType<String>().toList();
    } catch (_) {}
    return const [];
  }

  /// 6 quick emojis: saved ones, gaps filled with the defaults.
  static List<String> cleanQuick(List<String> saved) {
    final out = <String>[];
    for (final e in saved) {
      if (out.length == defaults.length) break;
      if (validEmoji(e) && !out.contains(e)) out.add(e);
    }
    for (final d in defaults) {
      if (out.length == defaults.length) break;
      if (!out.contains(d)) out.add(d);
    }
    return out;
  }

  /// A reaction is one short emoji (the database allows up to 16 chars).
  static bool validEmoji(String e) =>
      e.isNotEmpty && e.length <= 16 && e.characters.length == 1;

  /// Puts [emoji] in quick slot [slot] (if it is in another slot already,
  /// the two swap).
  Future<void> setSlot(int slot, String emoji) async {
    final now = [...emojis.value];
    if (slot < 0 || slot >= now.length || !validEmoji(emoji)) return;
    final at = now.indexOf(emoji);
    if (at >= 0) now[at] = now[slot];
    now[slot] = emoji;
    emojis.value = List.unmodifiable(now);
    await _save(_kQuick, now);
  }

  Future<void> reset() async {
    emojis.value = defaults;
    await _save(_kQuick, defaults);
  }

  Future<void> addRecent(String emoji) async {
    if (!validEmoji(emoji)) return;
    final now = [emoji, ...recent.value.where((e) => e != emoji)]
        .take(maxRecent)
        .toList();
    recent.value = List.unmodifiable(now);
    await _save(_kRecent, now);
  }

  Future<void> _save(String key, List<String> v) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(key, jsonEncode(v));
    } catch (e) {
      debugPrint('quick reactions: $e');
    }
  }

  /// Tests.
  void debugReset() {
    _loaded = false;
    emojis.value = defaults;
    recent.value = const [];
  }
}

/// "+" on the reactions row: every emoji, and "Your quick reactions"
/// (tap one, then an emoji to swap it). Returns the emoji to react with
/// (null = closed). [editSlot] = start with that quick slot chosen.
Future<String?> showEmojiPicker(BuildContext context, {int? editSlot}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppColors.surface,
    builder: (_) => EmojiPickerSheet(editSlot: editSlot),
  );
}

class EmojiPickerSheet extends StatefulWidget {
  const EmojiPickerSheet({super.key, this.editSlot});
  final int? editSlot;

  @override
  State<EmojiPickerSheet> createState() => _EmojiPickerSheetState();
}

class _EmojiPickerSheetState extends State<EmojiPickerSheet> {
  final _quick = QuickReactions.instance;
  late int? _slot = widget.editSlot;
  final _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _tapEmoji(String e) {
    final slot = _slot;
    if (slot != null) {
      // swap the chosen quick reaction, stay here
      _quick.setSlot(slot, e);
      setState(() => _slot = null);
      return;
    }
    _quick.addRecent(e);
    Navigator.of(context).pop(e);
  }

  void _jump(int group) {
    final ctx = _keys[group]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Widget _grid(List<String> list, String keyPrefix) => GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    padding: const EdgeInsets.symmetric(horizontal: 8),
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 46,
      mainAxisExtent: 46,
    ),
    itemCount: list.length,
    itemBuilder: (_, i) => GestureDetector(
      key: ValueKey('$keyPrefix${list[i]}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _tapEmoji(list[i]),
      child: Center(
        child: Text(list[i], style: const TextStyle(fontSize: 27)),
      ),
    ),
  );

  Widget _title(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
    child: Text(
      t,
      style: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        color: AppColors.textSecondary,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    return SizedBox(
      height: h * 0.72,
      child: Column(
        children: [
          // ---- your quick reactions (the sheet shows its own drag bar)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Your quick reactions',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                TextButton(
                  key: const ValueKey('quick-reset'),
                  onPressed: () {
                    _quick.reset();
                    setState(() => _slot = null);
                  },
                  child: const Text('Reset'),
                ),
              ],
            ),
          ),
          ValueListenableBuilder<List<String>>(
            valueListenable: _quick.emojis,
            builder: (_, quick, _) => Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (var i = 0; i < quick.length; i++)
                  GestureDetector(
                    key: ValueKey('quick-slot-$i'),
                    onTap: () => setState(() => _slot = _slot == i ? null : i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _slot == i
                            ? AppColors.surfaceHigh
                            : Colors.transparent,
                        border: Border.all(
                          color: _slot == i
                              ? AppColors.lime
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Text(
                        quick[i],
                        style: const TextStyle(fontSize: 26),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
            child: Text(
              _slot == null
                  ? 'Tap one to change it · tap an emoji below to react'
                  : 'Now tap the new emoji',
              key: const ValueKey('quick-hint'),
              style: TextStyle(
                fontSize: 12,
                color: _slot == null ? AppColors.textSecondary : AppColors.lime,
              ),
            ),
          ),
          // ---- group tabs
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (var g = 0; g < kEmojiGroups.length; g++)
                  IconButton(
                    key: ValueKey('emoji-group-$g'),
                    tooltip: kEmojiGroups[g].$1,
                    onPressed: () => _jump(g),
                    icon: Icon(
                      kEmojiGroups[g].$2,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          Expanded(
            child: SingleChildScrollView(
              controller: _scroll,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ValueListenableBuilder<List<String>>(
                    valueListenable: _quick.recent,
                    builder: (_, rec, _) => rec.isEmpty
                        ? const SizedBox.shrink()
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _title('Recent'),
                              _grid(rec, 'emoji-recent-'),
                            ],
                          ),
                  ),
                  for (var g = 0; g < kEmojiGroups.length; g++)
                    Column(
                      key: _keys.putIfAbsent(g, GlobalKey.new),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _title(kEmojiGroups[g].$1),
                        _grid(emojisOf(kEmojiGroups[g].$3), 'emoji-pick-'),
                      ],
                    ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
