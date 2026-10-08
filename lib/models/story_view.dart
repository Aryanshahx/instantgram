import 'package:cloud_firestore/cloud_firestore.dart';

/// How long a moment stays up: 24 hours, or 48 when chosen while sharing.
const int kStoryHours = 24;
const int kStoryLongHours = 48;

/// When a moment shared at [now] disappears.
DateTime storyExpiry(DateTime now, bool longer) =>
    now.add(Duration(hours: longer ? kStoryLongHours : kStoryHours));

/// One person who watched one of my moments: `stories/{id}/views/{uid}`.
/// Only the moment's author can read these (and each viewer their own line).
class StoryView {
  const StoryView({
    required this.uid,
    required this.username,
    this.photoUrl = '',
    required this.first,
    required this.last,
    this.count = 1,
  });

  final String uid;
  final String username;
  final String photoUrl;

  /// When they watched it the first and the last time.
  final DateTime first;
  final DateTime last;

  /// How many times they watched it (more than 1 = rewatched).
  final int count;

  bool get rewatched => count > 1;

  factory StoryView.fromMap(String uid, Map<String, dynamic> m) {
    DateTime t(Object? v) => v is Timestamp ? v.toDate() : DateTime.now();
    final last = t(m['last']);
    return StoryView(
      uid: uid,
      username: m['username'] is String ? m['username'] as String : '',
      photoUrl: m['photoUrl'] is String ? m['photoUrl'] as String : '',
      first: m['first'] is Timestamp ? t(m['first']) : last,
      last: last,
      count: m['count'] is num ? (m['count'] as num).toInt().clamp(1, 9999) : 1,
    );
  }

  /// The search box of the viewer list: username, case and a leading @ ignored.
  static List<StoryView> filter(List<StoryView> all, String query) {
    var q = query.trim().toLowerCase();
    if (q.startsWith('@')) q = q.substring(1);
    if (q.isEmpty) return all;
    return [
      for (final v in all)
        if (v.username.toLowerCase().contains(q)) v,
    ];
  }

  /// Newest first; people who rewatched more come first at the same time.
  static List<StoryView> sorted(List<StoryView> all) => [...all]
    ..sort((a, b) {
      final t = b.last.compareTo(a.last);
      return t != 0 ? t : b.count.compareTo(a.count);
    });
}

/// "Watched 3 times" / "" for once.
String rewatchLabel(int count) => count > 1 ? 'Watched $count times' : '';

/// "9:41 PM" for today, "Yesterday 9:41 PM" otherwise.
String viewTimeLabel(DateTime t, DateTime now) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  final clock = '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return clock;
  if (diff == 1) return 'Yesterday $clock';
  return '${t.day}/${t.month} $clock';
}
