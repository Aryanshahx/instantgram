import '../../../shared/models/post.dart';

/// v0.14: "typing…" without trusting the phone clocks.
///
/// The typing person writes a new server time every few seconds. Here a
/// NEW value means "typing right now" (counted from when THIS phone got
/// it), so a wrong clock on either phone can't hide or delay it.
class TypingTracker {
  TypingTracker({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  static final TypingTracker instance = TypingTracker();

  /// How long "typing…" stays after the last signal (the typing phone
  /// sends one every [ping]).
  static const Duration show = Duration(seconds: 6);
  static const Duration ping = Duration(seconds: 3);

  final DateTime Function() _clock;
  final Map<String, (DateTime, DateTime)> _seen = {}; // value, got at

  bool isTyping(Chat chat, String uid, {DateTime? serverNow}) {
    final stamp = chat.typing[uid];
    final key = '${chat.id}|$uid';
    if (stamp == null) {
      _seen.remove(key);
      return false;
    }
    final now = _clock();
    final prev = _seen[key];
    if (prev == null || prev.$1 != stamp) {
      // first time we see this chat: skip leftovers from long ago
      // (app closed while typing). Changes are always fresh.
      final fresh =
          prev != null ||
          (serverNow ?? now).difference(stamp).abs() <
              const Duration(seconds: 45);
      _seen[key] = (stamp, fresh ? now : DateTime(2000));
      return fresh;
    }
    return now.difference(prev.$2) < show;
  }

  /// Time left before "typing…" goes away (null = not typing).
  Duration? left(Chat chat, String uid) {
    final v = _seen['${chat.id}|$uid'];
    if (v == null || chat.typing[uid] != v.$1) return null;
    final rest = show - _clock().difference(v.$2);
    return rest.isNegative ? null : rest;
  }

  void clear() => _seen.clear();
}
