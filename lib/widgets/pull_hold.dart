import 'dart:async';

import 'package:flutter/widgets.dart';

/// Pull down and hold: feed it the notifications of a reversed (chat) list. Pulling the
/// top edge further than [distance] and keeping the finger there for [hold] calls [onFire].
class PullHold {
  PullHold({
    required this.onFire,
    this.distance = 70,
    this.hold = const Duration(milliseconds: 600),
  });

  final VoidCallback onFire;
  final double distance;
  final Duration hold;

  /// 0 … 1 while pulling (1 = far enough, keep holding); 0 otherwise.
  final ValueNotifier<double> progress = ValueNotifier(0);

  double _pulled = 0;
  Timer? _timer;
  bool _fired = false;

  /// Feed it every [ScrollNotification]; returns false so others still get them.
  bool handle(ScrollNotification n) {
    if (n is ScrollStartNotification) {
      _reset();
    } else if (n is OverscrollNotification) {
      // a reversed list: the top (older messages) is the far end
      if (n.dragDetails != null && n.overscroll > 0) _add(n.overscroll);
    } else if (n is ScrollUpdateNotification) {
      final m = n.metrics;
      if (n.dragDetails != null && m.pixels > m.maxScrollExtent) {
        _set(
          m.pixels - m.maxScrollExtent,
        ); // bouncing lists (iOS) go past the edge
      } else if ((n.scrollDelta ?? 0) < 0) {
        _reset(); // pulled back
      }
    } else if (n is ScrollEndNotification) {
      _reset();
    }
    return false;
  }

  void _add(double d) => _set(_pulled + d);

  void _set(double v) {
    if (_fired) return;
    _pulled = v;
    progress.value = (_pulled / distance).clamp(0.0, 1.0);
    if (_pulled >= distance && _timer == null) {
      _timer = Timer(hold, () {
        _fired = true;
        progress.value = 0;
        onFire();
      });
    }
  }

  void _reset() {
    _timer?.cancel();
    _timer = null;
    _pulled = 0;
    _fired = false;
    progress.value = 0;
  }

  void dispose() {
    _timer?.cancel();
    progress.dispose();
  }
}
