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
