import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Built-in chat backgrounds: doodle patterns and gradients, drawn in code
/// (no files, nothing uploaded). Saved like a background photo, as
/// `wp:<id>`, only on this phone.
@immutable
class ChatWallpaper {
  const ChatWallpaper.doodle({
    required this.id,
    required this.name,
    required this.colors,
    required this.ink,
    required this.icons,
  });

  const ChatWallpaper.gradient({
    required this.id,
    required this.name,
    required this.colors,
  }) : ink = const Color(0x00000000),
       icons = const [];

  final String id;
  final String name;

  /// Background colours (top-left -> bottom-right).
  final List<Color> colors;

  /// Doodle colour (see-through) and the doodles.
  final Color ink;
  final List<IconData> icons;

  bool get isDoodle => icons.isNotEmpty;

  static const String prefix = 'wp:';

  /// What is saved for this background.
  String get value => '$prefix$id';

  /// `wp:<id>` -> the background; a photo path / unknown -> null.
  static ChatWallpaper? fromValue(String v) {
    if (!v.startsWith(prefix)) return null;
    final id = v.substring(prefix.length);
    for (final w in all) {
      if (w.id == id) return w;
    }
    return null;
  }

  static bool isWallpaper(String v) => v.startsWith(prefix);

  static const List<ChatWallpaper> doodles = [
    ChatWallpaper.doodle(
      id: 'd_classic',
      name: 'Classic',
      colors: [Color(0xFF0B0F0A), Color(0xFF111A0E)],
      ink: Color(0x24C6F432),
      icons: [
        Icons.chat_bubble_outline,
        Icons.favorite_border,
        Icons.star_border,
        Icons.sentiment_satisfied_alt,
        Icons.camera_alt_outlined,
        Icons.music_note,
        Icons.local_cafe_outlined,
        Icons.send_outlined,
      ],
    ),
    ChatWallpaper.doodle(
      id: 'd_love',
      name: 'Love',
      colors: [Color(0xFF1A070E), Color(0xFF2A0C18)],
      ink: Color(0x2EFF6B9A),
      icons: [
        Icons.favorite,
        Icons.favorite_border,
        Icons.volunteer_activism_outlined,
        Icons.local_florist_outlined,
        Icons.auto_awesome,
        Icons.mail_outline,
      ],
    ),
    ChatWallpaper.doodle(
      id: 'd_space',
      name: 'Space',
      colors: [Color(0xFF05061A), Color(0xFF0E0F2E)],
      ink: Color(0x2E9FA8FF),
      icons: [
        Icons.rocket_launch_outlined,
        Icons.star,
        Icons.nightlight_outlined,
        Icons.public,
        Icons.satellite_alt_outlined,
        Icons.auto_awesome,
        Icons.flare,
      ],
    ),
    ChatWallpaper.doodle(
      id: 'd_music',
      name: 'Music',
      colors: [Color(0xFF120A1C), Color(0xFF1C1030)],
      ink: Color(0x2EC084FC),
      icons: [
        Icons.music_note,
        Icons.queue_music,
        Icons.headphones_outlined,
        Icons.mic_none,
        Icons.piano_outlined,
        Icons.graphic_eq,
        Icons.album_outlined,
      ],
    ),
    ChatWallpaper.doodle(
      id: 'd_food',
      name: 'Food',
      colors: [Color(0xFF1A1006), Color(0xFF26170A)],
      ink: Color(0x2EFFB347),
      icons: [
        Icons.local_pizza_outlined,
        Icons.icecream_outlined,
        Icons.cake_outlined,
        Icons.local_cafe_outlined,
        Icons.lunch_dining_outlined,
        Icons.ramen_dining_outlined,
        Icons.bakery_dining_outlined,
      ],
    ),
    ChatWallpaper.doodle(
      id: 'd_travel',
      name: 'Travel',
      colors: [Color(0xFF041419), Color(0xFF082029)],
      ink: Color(0x2E5EEAD4),
      icons: [
        Icons.flight_outlined,
        Icons.map_outlined,
        Icons.photo_camera_outlined,
        Icons.beach_access_outlined,
        Icons.luggage_outlined,
        Icons.explore_outlined,
        Icons.landscape_outlined,
      ],
    ),
    ChatWallpaper.doodle(
      id: 'd_nature',
      name: 'Nature',
      colors: [Color(0xFF06140A), Color(0xFF0B2112)],
      ink: Color(0x2E6EE7A0),
      icons: [
        Icons.eco_outlined,
        Icons.local_florist_outlined,
        Icons.wb_sunny_outlined,
        Icons.water_drop_outlined,
        Icons.park_outlined,
        Icons.filter_vintage_outlined,
        Icons.grass,
      ],
    ),
    ChatWallpaper.doodle(
      id: 'd_pets',
      name: 'Pets',
      colors: [Color(0xFF15100A), Color(0xFF221A10)],
      ink: Color(0x2EF5D0A9),
      icons: [
        Icons.pets,
        Icons.cruelty_free_outlined,
        Icons.set_meal_outlined,
        Icons.favorite_border,
        Icons.home_outlined,
        Icons.sports_baseball_outlined,
      ],
    ),
    ChatWallpaper.doodle(
      id: 'd_games',
      name: 'Games',
      colors: [Color(0xFF0A0A1A), Color(0xFF13122A)],
      ink: Color(0x2E7DD3FC),
      icons: [
        Icons.sports_esports_outlined,
        Icons.casino_outlined,
        Icons.extension_outlined,
        Icons.emoji_events_outlined,
        Icons.videogame_asset_outlined,
        Icons.bolt,
      ],
    ),
    ChatWallpaper.doodle(
      id: 'd_sports',
      name: 'Sports',
      colors: [Color(0xFF0C1206), Color(0xFF16200C)],
      ink: Color(0x2EBEF264),
      icons: [
        Icons.sports_soccer,
        Icons.sports_basketball_outlined,
        Icons.sports_cricket_outlined,
        Icons.sports_tennis,
        Icons.directions_bike,
        Icons.fitness_center,
        Icons.emoji_events_outlined,
      ],
    ),
    ChatWallpaper.doodle(
      id: 'd_party',
      name: 'Party',
      colors: [Color(0xFF1A0816), Color(0xFF240E22)],
      ink: Color(0x2EF0ABFC),
      icons: [
        Icons.celebration_outlined,
        Icons.cake_outlined,
        Icons.card_giftcard,
        Icons.auto_awesome,
        Icons.local_bar_outlined,
        Icons.music_note,
        Icons.star_border,
      ],
    ),
    ChatWallpaper.doodle(
      id: 'd_night',
      name: 'Night',
      colors: [Color(0xFF04070F), Color(0xFF0A1020)],
      ink: Color(0x2693C5FD),
      icons: [
        Icons.bedtime_outlined,
        Icons.star_border,
        Icons.cloud_outlined,
        Icons.nights_stay_outlined,
        Icons.auto_awesome,
        Icons.light_mode_outlined,
      ],
    ),
  ];

  static const List<ChatWallpaper> gradients = [
    ChatWallpaper.gradient(
      id: 'g_aurora',
      name: 'Aurora',
      colors: [Color(0xFF041A14), Color(0xFF0B2D2A), Color(0xFF1B1440)],
    ),
    ChatWallpaper.gradient(
      id: 'g_sunset',
      name: 'Sunset',
      colors: [Color(0xFF2A0F1E), Color(0xFF3B1420), Color(0xFF3D2410)],
    ),
    ChatWallpaper.gradient(
      id: 'g_ocean',
      name: 'Ocean',
      colors: [Color(0xFF031322), Color(0xFF07263D), Color(0xFF0B3B4A)],
    ),
    ChatWallpaper.gradient(
      id: 'g_midnight',
      name: 'Midnight',
      colors: [Color(0xFF05050F), Color(0xFF0D1030), Color(0xFF1A0F33)],
    ),
    ChatWallpaper.gradient(
      id: 'g_peach',
      name: 'Peach',
      colors: [Color(0xFF2B1612), Color(0xFF3A1F1A), Color(0xFF2E1525)],
    ),
    ChatWallpaper.gradient(
      id: 'g_mint',
      name: 'Mint',
      colors: [Color(0xFF06170F), Color(0xFF0C2A1E), Color(0xFF0A2228)],
    ),
    ChatWallpaper.gradient(
      id: 'g_neon',
      name: 'Neon',
      colors: [Color(0xFF0A0F02), Color(0xFF17260A), Color(0xFF09221F)],
    ),
    ChatWallpaper.gradient(
      id: 'g_berry',
      name: 'Berry',
      colors: [Color(0xFF1C0619), Color(0xFF2D0B2E), Color(0xFF170B33)],
    ),
    ChatWallpaper.gradient(
      id: 'g_forest',
      name: 'Forest',
      colors: [Color(0xFF040E07), Color(0xFF0B1F11), Color(0xFF16240C)],
    ),
    ChatWallpaper.gradient(
      id: 'g_ember',
      name: 'Ember',
      colors: [Color(0xFF140504), Color(0xFF2E0B07), Color(0xFF3A1A06)],
    ),
    ChatWallpaper.gradient(
      id: 'g_lavender',
      name: 'Lavender',
      colors: [Color(0xFF120E22), Color(0xFF221A3A), Color(0xFF2C1A33)],
    ),
    ChatWallpaper.gradient(
      id: 'g_steel',
      name: 'Steel',
      colors: [Color(0xFF0A0D10), Color(0xFF151B22), Color(0xFF1F262E)],
    ),
  ];

  static const List<ChatWallpaper> all = [...doodles, ...gradients];
}

/// Draws a built-in background (fills its space).
class ChatWallpaperView extends StatelessWidget {
  const ChatWallpaperView({super.key, required this.wallpaper});

  final ChatWallpaper wallpaper;

  @override
  Widget build(BuildContext context) {
    final w = wallpaper;
    return RepaintBoundary(
      child: DecoratedBox(
        key: ValueKey('chat-wp-${w.id}'),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: w.colors,
          ),
        ),
        child: w.isDoodle
            ? CustomPaint(painter: DoodlePainter(w), child: const SizedBox.expand())
            : const SizedBox.expand(),
      ),
    );
  }
}

/// Icons in a loose, tilted grid (same look every time).
class DoodlePainter extends CustomPainter {
  DoodlePainter(this.wallpaper, {this.cell = 58});

  final ChatWallpaper wallpaper;
  final double cell;

  final Map<int, TextPainter> _cache = {};

  TextPainter _glyph(IconData icon, double size) {
    final key = icon.codePoint * 100 + size.round();
    return _cache.putIfAbsent(key, () {
      return TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            fontSize: size,
            color: wallpaper.ink,
          ),
        ),
      )..layout();
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final icons = wallpaper.icons;
    if (icons.isEmpty || size.isEmpty) return;
    final cols = (size.width / cell).ceil() + 1;
    final rows = (size.height / cell).ceil() + 1;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        // small fixed "random" from the cell position
        final h = ((r * 73856093) ^ (c * 19349663)) & 0x7fffffff;
        final icon = icons[(h ~/ 7 + r + c * 3) % icons.length];
        final s = 20.0 + (h % 4) * 3; // 20..29
        final dx = c * cell + (r.isOdd ? cell / 2 : 0) + (h % 11) - 5;
        final dy = r * cell + ((h ~/ 11) % 11) - 5;
        final angle = (((h ~/ 121) % 41) - 20) * math.pi / 180;
        final tp = _glyph(icon, s);
        canvas
          ..save()
          ..translate(dx, dy)
          ..rotate(angle);
        tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(DoodlePainter old) =>
      old.wallpaper.id != wallpaper.id || old.cell != cell;
}
