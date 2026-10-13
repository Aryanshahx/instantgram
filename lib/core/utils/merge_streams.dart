import 'dart:async';

/// Listens to all [streams] and emits [combine] of their latest values.
/// Waits until every stream sent its first value (no half-empty flash),
/// then emits on every change.
Stream<R> combineLatestList<T, R>(
  List<Stream<T>> streams,
  R Function(List<T> latest) combine,
) {
  if (streams.isEmpty) return Stream<R>.value(combine(<T>[]));
  if (streams.length == 1) {
    return streams.first.map((v) => combine(<T>[v]));
  }
  late StreamController<R> ctrl;
  final subs = <StreamSubscription<T>>[];
  final latest = List<T?>.filled(streams.length, null);
  final has = List<bool>.filled(streams.length, false);

  final got = List<bool>.filled(streams.length, false);

  void emit() {
    if (!has.every((h) => h)) return;
    // parts that failed before sending anything are left out
    ctrl.add(
      combine([
        for (var i = 0; i < latest.length; i++)
          if (got[i]) latest[i] as T,
      ]),
    );
  }

  ctrl = StreamController<R>(
    onListen: () {
      for (var i = 0; i < streams.length; i++) {
        subs.add(
          streams[i].listen(
            (v) {
              latest[i] = v;
              got[i] = true;
              has[i] = true;
              emit();
            },
            onError: (Object e, StackTrace st) {
              // a failing part counts as empty instead of breaking all
              if (!has[i]) {
                has[i] = true;
                emit();
              }
            },
          ),
        );
      }
    },
    onCancel: () async {
      for (final s in subs) {
        await s.cancel();
      }
    },
  );
  return ctrl.stream;
}
