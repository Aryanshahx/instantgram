import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';

/// v0.15: one person who watched a moment (`stories/{id}/views/{uid}`).
/// [count] = how many times they watched it (rewatches = count - 1).
class StoryView {
  const StoryView({
    required this.uid,
    required this.username,
    required this.photoUrl,
    required this.count,
    this.lastAt,
  });

  final String uid;
  final String username;
  final String photoUrl;
  final int count;
  final DateTime? lastAt;

  int get rewatches => math.max(0, count - 1);

  factory StoryView.fromMap(String id, Map<String, dynamic> m) => StoryView(
    uid: id,
    username: m['username'] is String ? m['username'] as String : '',
    photoUrl: m['photoUrl'] is String ? m['photoUrl'] as String : '',
    count: m['count'] is num ? math.max(1, (m['count'] as num).toInt()) : 1,
    lastAt: m['lastAt'] is Timestamp
        ? (m['lastAt'] as Timestamp).toDate()
        : null,
  );
}

/// Numbers for the "Seen by" bar and the viewer list.
class StoryInsights {
  StoryInsights._();

  /// (people, rewatches)
  static (int, int) totals(List<StoryView> views) {
    var re = 0;
    for (final v in views) {
      re += v.rewatches;
    }
    return (views.length, re);
  }

  /// Search by username (no @, any case).
  static List<StoryView> search(List<StoryView> views, String query) {
    final q = query.trim().toLowerCase().replaceFirst('@', '');
    if (q.isEmpty) return views;
    return views.where((v) => v.username.toLowerCase().contains(q)).toList();
  }

  /// Newest first, or most watched first.
  static List<StoryView> sorted(
    List<StoryView> views, {
    bool mostWatched = false,
  }) {
    final out = [...views];
    final old = DateTime(2000);
    out.sort((a, b) {
      if (mostWatched && a.count != b.count) return b.count.compareTo(a.count);
      return (b.lastAt ?? old).compareTo(a.lastAt ?? old);
    });
    return out;
  }

  /// "Watched 3 times" / "Watched once".
  static String watchedLabel(int count) =>
      count <= 1 ? 'Watched once' : 'Watched $count times';
}
