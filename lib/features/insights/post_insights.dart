import 'package:cloud_firestore/cloud_firestore.dart';

import '../../shared/models/post.dart';
import '../post/data/post_repository.dart' show ViewSource, kAgeGroups;

/// Numbers for ONE post / clip, made from its view docs.
/// Only totals — never who watched.
class PostInsights {
  PostInsights._({
    required this.post,
    required this.views,
    required this.reach,
    required this.detailed,
    required this.followerViews,
    required this.countries,
    required this.ages,
    required this.sources,
    required this.languages,
    required this.watchSamples,
    required this.avgWatchMs,
    required this.completionRate,
    required this.timeline,
    required this.hourly,
  });

  final Post post;

  /// All views, also repeat views by the same account.
  final int views;

  /// Accounts that saw it (one each).
  final int reach;

  /// View docs with details (from v0.5.0 on).
  final int detailed;
  final int followerViews;
  int get nonFollowerViews => detailed - followerViews;

  /// Sorted, biggest first: (key, count).
  final List<(String, int)> countries;

  /// In age order (13-17 ... 55+), only groups with views.
  final List<(String, int)> ages;
  final List<(String, int)> sources;
  final List<(String, int)> languages;

  /// Videos only.
  final int watchSamples;
  final double avgWatchMs;

  /// 0..1 part of viewers who watched to the end.
  final double completionRate;

  /// Views per day (or per hour when the post is younger than 2 days).
  final List<(DateTime, int)> timeline;
  final bool hourly;

  int get likes => post.likesCount;
  int get comments => post.commentsCount;
  int get shares => post.sharesCount;
  int get reposts => post.repostsCount;
  int get saves => post.savesCount < 0 ? 0 : post.savesCount;
  int get interactions => likes + comments + shares + reposts + saves;

  /// Interactions per account reached (0..∞, shown as %).
  double get engagementRate => reach == 0 ? 0 : interactions / reach;

  static DateTime? _date(Object? v) {
    if (v is Timestamp) return v.toDate();
    if (v is DateTime) return v;
    return null;
  }

  static List<(String, int)> _sorted(Map<String, int> m) {
    final list = m.entries.map((e) => (e.key, e.value)).toList()
      ..sort((a, b) {
        final c = b.$2.compareTo(a.$2);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    return list;
  }

  factory PostInsights.from(
    Post post,
    List<Map<String, dynamic>> docs, {
    DateTime? now,
  }) {
    final n = now ?? DateTime.now();
    var views = 0, followers = 0, watchN = 0, watchSum = 0, done = 0;
    final countries = <String, int>{};
    final ages = <String, int>{};
    final sources = <String, int>{};
    final langs = <String, int>{};
    final dates = <DateTime>[];
    for (final d in docs) {
      final c = d['count'];
      views += c is num && c >= 1 ? c.toInt() : 1;
      if (d['follower'] == true) followers++;
      final country = d['country'];
      if (country is String && country.isNotEmpty) {
        countries[country.toUpperCase()] =
            (countries[country.toUpperCase()] ?? 0) + 1;
      }
      final age = d['ageGroup'];
      if (age is String && kAgeGroups.contains(age)) {
        ages[age] = (ages[age] ?? 0) + 1;
      }
      final src = ViewSource.normalize(
        d['source'] is String ? d['source'] as String : '',
      );
      sources[src] = (sources[src] ?? 0) + 1;
      final lang = d['language'];
      if (lang is String && lang.isNotEmpty) {
        langs[lang] = (langs[lang] ?? 0) + 1;
      }
      final w = d['watchMs'];
      if (w is num && w > 0) {
        watchN++;
        watchSum += w.toInt();
      }
      if (d['completed'] == true) done++;
      final at = _date(d['createdAt']);
      if (at != null) dates.add(at);
    }

    // timeline: hours for young posts, else days (max 30 buckets)
    final start = post.createdAt;
    final age = n.difference(start);
    final hourly = age.inHours < 48;
    final step = hourly ? const Duration(hours: 1) : const Duration(days: 1);
    DateTime floor(DateTime t) => hourly
        ? DateTime(t.year, t.month, t.day, t.hour)
        : DateTime(t.year, t.month, t.day);
    final first = floor(start);
    var buckets = hourly ? age.inHours + 1 : age.inDays + 1;
    if (buckets < 1) buckets = 1;
    final shown = buckets > 30 ? 30 : buckets;
    final from = buckets > 30 ? floor(n).subtract(step * (shown - 1)) : first;
    final counts = List<int>.filled(shown, 0);
    for (final t in dates) {
      final i = floor(t).difference(from).inMinutes ~/ step.inMinutes;
      if (i >= 0 && i < shown) counts[i]++;
    }
    final timeline = [
      for (var i = 0; i < shown; i++) (from.add(step * i), counts[i]),
    ];

    final reach = docs.length > post.viewsCount ? docs.length : post.viewsCount;
    return PostInsights._(
      post: post,
      views: views < reach ? reach : views,
      reach: reach,
      detailed: docs.length,
      followerViews: followers,
      countries: _sorted(countries),
      ages: [
        for (final g in kAgeGroups)
          if ((ages[g] ?? 0) > 0) (g, ages[g]!),
      ],
      sources: _sorted(sources),
      languages: _sorted(langs),
      watchSamples: watchN,
      avgWatchMs: watchN == 0 ? 0 : watchSum / watchN,
      completionRate: docs.isEmpty ? 0 : done / docs.length,
      timeline: timeline,
      hourly: hourly,
    );
  }
}
