/// v0.0.1: a view counts after 3 seconds of real watching.
///
/// Adds up only the time the video was really playing (not paused, not
/// loading). Photos: the time they were on screen. A video shorter than
/// 3 s counts when it reached the end. Fires once.
class WatchClock {
  WatchClock({this.needMs = viewAfterMs});

  /// 3 seconds.
  static const int viewAfterMs = 3000;

  final int needMs;
  int _playedMs = 0;
  int? _since;
  bool _done = false;

  int get playedMs => _playedMs;
  bool get done => _done;

  /// Call on every player update. Returns true ONCE: when the view counts.
  bool update({
    required bool playing,
    required int nowMs,
    bool completed = false,
  }) {
    if (_done) return false;
    final since = _since;
    if (since != null && nowMs > since) {
      // big jumps (phone asleep, app in background) count at most 1 s
      final d = nowMs - since;
      _playedMs += d > 1000 ? 1000 : d;
    }
    _since = playing ? nowMs : null;
    if (_playedMs >= needMs || completed) {
      _done = true;
      return true;
    }
    return false;
  }

  /// Stopped (off screen / closed): the time so far is kept.
  void pause(int nowMs) => update(playing: false, nowMs: nowMs);
}
