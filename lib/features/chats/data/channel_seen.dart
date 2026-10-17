import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/server_clock.dart';
import '../../../shared/models/post.dart';

/// v0.0.2: when you last opened each channel (kept on this phone).
/// Channels can have thousands of followers, so nobody writes "seen"
/// into the channel itself; the unread dot comes from here.
class ChannelSeen {
  ChannelSeen._();
  static final ChannelSeen instance = ChannelSeen._();

  static const String _key = 'channel_seen';

  /// channel id -> last opened (ms since 1970). Changes redraw the list.
  final ValueNotifier<Map<String, int>> value = ValueNotifier(const {});
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null) return;
      final m = jsonDecode(raw);
      if (m is! Map) return;
      value.value = {
        for (final e in m.entries)
          if (e.value is int) '${e.key}': e.value as int,
        ...value.value,
      };
    } catch (e) {
      debugPrint('channel seen: $e');
    }
  }

  /// You opened [channelId] now.
  Future<void> mark(String channelId, {DateTime? at}) async {
    final t = (at ?? ServerClock.now()).millisecondsSinceEpoch;
    final next = {...value.value, channelId: t};
    // keep it small: the newest 300 channels
    if (next.length > 300) {
      final ids = next.keys.toList()
        ..sort((a, b) => next[a]!.compareTo(next[b]!));
      for (final id in ids.take(next.length - 300)) {
        next.remove(id);
      }
    }
    value.value = next;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode(next));
    } catch (e) {
      debugPrint('channel seen: $e');
    }
  }

  /// A new post you have not opened yet.
  bool unread(Chat c, String me) =>
      unreadIn(c, me, value.value[c.id]);

  static bool unreadIn(Chat c, String me, int? seenMs) {
    if (c.lastSenderId.isEmpty || c.lastSenderId == me) return false;
    if (seenMs == null) return true;
    return c.updatedAt.millisecondsSinceEpoch > seenMs;
  }
}
