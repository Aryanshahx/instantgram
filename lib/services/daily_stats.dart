import 'package:cloud_firestore/cloud_firestore.dart';

import 'app_prefs.dart';

/// "2026-10-09" for [t] in UTC (the admin panel charts use the same days).
String statsDay(DateTime t) {
  final u = t.toUtc();
  return '${u.year.toString().padLeft(4, '0')}-${u.month.toString().padLeft(2, '0')}-${u.day.toString().padLeft(2, '0')}';
}

/// Test hook: gets the day instead of writing to Firestore.
void Function(String day)? debugDailySink;

/// Counts this person once per day in dailyStats/{day}.active (admin panel: active users).
Future<void> countActiveToday(String uid, {DateTime? now}) async {
  if (uid.isEmpty) return;
  final day = statsDay(now ?? DateTime.now());
  final mark = '$uid@$day';
  if (AppPrefs.instance.activeCounted == mark) return;
  AppPrefs.instance.activeCounted = mark;
  final sink = debugDailySink;
  if (sink != null) {
    sink(day);
    return;
  }
  try {
    await FirebaseFirestore.instance.collection('dailyStats').doc(day).set({
      'active': FieldValue.increment(1),
    }, SetOptions(merge: true));
  } catch (_) {
    // a missed count is fine
  }
}
