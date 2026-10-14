/// The phone clock can be wrong by minutes (or hours). Times saved by
/// Firestore are server times, so "Active now", disappearing messages and
/// call timeouts compare against [ServerClock.now] (v0.11).
///
/// The difference is learned from our own presence write: we know when
/// we sent it (phone time) and the server time it got.
class ServerClock {
  ServerClock._();

  /// server time - phone time.
  static Duration offset = Duration.zero;

  static DateTime now() => DateTime.now().add(offset);

  /// [server] = the time the server saved, [sentAt] / [doneAt] = phone
  /// time before and after the write.
  static void learn(DateTime server, DateTime sentAt, DateTime doneAt) {
    final trip = doneAt.difference(sentAt);
    if (trip.isNegative || trip > const Duration(seconds: 20)) return;
    final mid = sentAt.add(trip ~/ 2);
    final o = server.difference(mid);
    if (o.abs() > const Duration(days: 3)) return; // nonsense
    offset = o;
  }
}
