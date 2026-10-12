/// Turns Firebase / network errors into short readable text.
String friendlyError(Object? e) {
  final s = e.toString();
  if (s.contains('requires an index') || s.contains('FAILED_PRECONDITION')) {
    return 'Database is still setting up. Try again in a few minutes.';
  }
  if (s.contains('permission-denied') || s.contains('PERMISSION_DENIED')) {
    return 'Permission denied. Database rules may not be deployed yet.';
  }
  if (s.contains('unavailable') || s.contains('network')) {
    return 'No internet connection.';
  }
  return s.replaceFirst(RegExp(r'^\[[^\]]+\]\s*'), '');
}
