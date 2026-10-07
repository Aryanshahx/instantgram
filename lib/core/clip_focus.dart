import 'package:flutter/foundation.dart';

/// Which clips screen is in front.
///
/// Opening a clip from a comment pushes a second clips screen on top of the first one, and
/// without this both would play at the same time. Every clips screen takes a token when it is
/// pushed; only the token that is on top is allowed to play. A clip inside the Discover feed
/// stops while any clips screen is open.
class ClipFocus {
  ClipFocus._() {
    // nothing to set up
  }
  static final ClipFocus instance = ClipFocus._();

  final List<Object> _stack = [];

  /// Bumped on every push and pop, so screens can rebuild.
  final ValueNotifier<int> version = ValueNotifier<int>(0);

  /// Takes a place in the stack (the most recent one plays).
  Object push() {
    final token = Object();
    _stack.add(token);
    version.value++;
    return token;
  }

  /// Gives the place back (when the screen is closed).
  void pop(Object? token) {
    if (token != null && _stack.remove(token)) version.value++;
  }

  /// [token] == null is the Discover feed: it plays only while nothing is open on top of it.
  bool canPlay(Object? token) {
    if (token == null) return _stack.isEmpty;
    return _stack.isNotEmpty && _stack.last == token;
  }

  /// true while a clips screen is open (the feed stays quiet then).
  bool get anyOpen => _stack.isNotEmpty;

  /// Tests: start from nothing.
  void reset() {
    _stack.clear();
    version.value++;
  }
}
