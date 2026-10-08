/// Disappearing messages: the modes a chat can be in.
class Vanish {
  Vanish._();

  /// Normal chat: messages stay.
  static const off = '';

  /// A message disappears once the other person has seen it and left the chat.
  static const seen = 'seen';
  static const day = '24h';
  static const week = '7d';
  static const all = [off, seen, day, week];

  static bool isValid(String mode) => all.contains(mode);

  static String label(String mode) => switch (mode) {
    seen => 'After seen',
    day => '24 hours',
    week => '7 days',
    _ => 'Off',
  };

  /// How long a message lives, for the timed modes.
  static Duration? lifetime(String mode) => switch (mode) {
    day => const Duration(hours: 24),
    week => const Duration(days: 7),
    _ => null,
  };

  /// When a message sent now in [mode] disappears (null: not on a timer).
  static DateTime? expireAt(String mode, DateTime now) {
    final d = lifetime(mode);
    return d == null ? null : now.add(d);
  }

  /// The line written into the chat when someone changes the mode.
  static String systemText(String who, String mode) => mode == off
      ? '$who turned off disappearing messages'
      : '$who turned on disappearing messages (${label(mode).toLowerCase()})';

  /// What the inbox shows instead of the content of a disappearing message.
  static const preview = 'Disappearing message';
}
