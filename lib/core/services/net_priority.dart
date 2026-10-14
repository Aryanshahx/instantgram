import 'dart:async';

import 'package:flutter/foundation.dart';

/// v0.13: "pull to refresh first".
///
/// While something the user is waiting for runs (pull to refresh), the
/// app's own background traffic (video pre-downloads, next videos, upload
/// parts) waits, so the refresh gets the whole connection.
class NetPriority {
  NetPriority._();

  /// > 0 = the user is waiting for the network.
  static final ValueNotifier<int> busy = ValueNotifier<int>(0);

  /// Background work should not start now.
  static bool get quiet => busy.value > 0;

  /// Longest time a refresh may keep the background waiting.
  static const Duration maxHold = Duration(seconds: 25);

  /// Runs [f] with background traffic paused.
  static Future<T> run<T>(Future<T> Function() f) async {
    busy.value = busy.value + 1;
    // never block the background forever (a stuck request)
    var released = false;
    void release() {
      if (released) return;
      released = true;
      busy.value = busy.value > 0 ? busy.value - 1 : 0;
    }

    final guard = Timer(maxHold, release);
    try {
      return await f();
    } finally {
      guard.cancel();
      release();
    }
  }

  /// Background work: waits until no refresh is running (at most [max]).
  static Future<void> waitQuiet({Duration max = maxHold}) async {
    if (!quiet) return;
    final done = Completer<void>();
    void check() {
      if (!quiet && !done.isCompleted) done.complete();
    }

    busy.addListener(check);
    try {
      await done.future.timeout(max, onTimeout: () {});
    } finally {
      busy.removeListener(check);
    }
  }

  /// Fetches from the server with background paused; true = got fresh data.
  static Future<bool> refresh(
    Future<void> Function() fetch, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      await run(() => fetch().timeout(timeout));
      return true;
    } catch (e) {
      debugPrint('refresh: $e');
      return false;
    }
  }
}
