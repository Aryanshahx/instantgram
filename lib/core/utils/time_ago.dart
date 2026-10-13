/// Short relative time like "~1d", "5m", "now".
String timeAgo(DateTime time, {bool approx = false}) {
  final diff = DateTime.now().difference(time);
  final prefix = approx ? '~' : '';
  if (diff.inSeconds < 60) return 'now';
  if (diff.inMinutes < 60) return '$prefix${diff.inMinutes}m';
  if (diff.inHours < 24) return '$prefix${diff.inHours}h';
  if (diff.inDays < 7) return '$prefix${diff.inDays}d';
  return '$prefix${(diff.inDays / 7).floor()}w';
}

/// 1200 -> 1.2K, 1500000 -> 1.5M
String compactCount(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    final v = n / 1000;
    return '${v.toStringAsFixed(v < 10 ? 1 : 0).replaceAll('.0', '')}K';
  }
  final v = n / 1000000;
  return '${v.toStringAsFixed(v < 10 ? 1 : 0).replaceAll('.0', '')}M';
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "12 Oct 2026, 3:45 PM"
String fullDate(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  final ampm = t.hour < 12 ? 'AM' : 'PM';
  return '${t.day} ${_months[t.month - 1]} ${t.year}, $h:$m $ampm';
}

/// "13 Oct 2006"
String shortDate(DateTime t) => '${t.day} ${_months[t.month - 1]} ${t.year}';

/// "1:05" or "12:30"
String durationLabel(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
