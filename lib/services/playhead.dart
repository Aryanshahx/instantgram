import 'dart:async';

/// Makes the playhead of a timeline move smoothly. The video player only reports its position
/// a few times a second, so between two reports the position is worked out from the clock:
/// it moves with every frame instead of in jumps.
class PlayheadSmoother {
  PlayheadSmoother({this.jump = 0.35, this.pull = 0.15});

  /// A report that differs from the estimate by more than this many seconds (a seek, a loop)
  /// is taken over at once.
  final double jump;

  /// Smaller differences are corrected by this fraction, so there is no visible step.
  final double pull;

  double _base = 0;
  Duration _at = Duration.zero;
  bool _playing = false;

  bool get playing => _playing;

  /// The position at [now] (seconds).
  double value(Duration now) =>
      _playing ? _base + (now - _at).inMicroseconds / 1e6 : _base;

  /// The player says it is at [sec].
  void report(double sec, bool playing, Duration now) {
    if (!playing || !_playing) {
      _base = sec;
      _at = now;
      _playing = playing;
      return;
    }
    final est = value(now);
    final diff = sec - est;
    _base = diff.abs() > jump ? sec : est + diff * pull;
    _at = now;
  }

  /// A seek: the position is exactly [sec] from now on.
  void seek(double sec, Duration now) {
    _base = sec;
    _at = now;
  }
}

/// Sends at most one seek every [gap] while a finger is dragging, always ending with the last
/// wanted position, so the video is not flooded with seeks.
class SeekThrottle {
  SeekThrottle(this.send, {this.gap = const Duration(milliseconds: 90)});

  final Future<void> Function(Duration target) send;
  final Duration gap;

  Timer? _timer;
  Duration? _pending;
  bool _busy = false;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  /// Number of seeks that were really sent (for tests).
  int sent = 0;

  void request(Duration target) {
    _pending = target;
    if (_busy || _timer != null) return;
    final wait = gap - DateTime.now().difference(_last);
    if (wait <= Duration.zero) {
      _fire();
    } else {
      _timer = Timer(wait, () {
        _timer = null;
        _fire();
      });
    }
  }

  /// Sends the wanted position at once (the finger was lifted).
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_pending != null && !_busy) _fire();
  }

  Future<void> _fire() async {
    final t = _pending;
    if (t == null) return;
    _pending = null;
    _busy = true;
    _last = DateTime.now();
    sent++;
    try {
      await send(t);
    } catch (_) {
      // a failed seek is simply skipped
    } finally {
      _busy = false;
      if (_pending != null) request(_pending!);
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }
}
