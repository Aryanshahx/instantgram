/// Smooth playing position between the video player's updates.
///
/// The player tells its position only now and then (about every half
/// second) and each answer is a little late. Jumping to every answer makes
/// a moving timeline / sticker shake. This clock runs on its own and only
/// gently follows the player: small differences are corrected slowly, it
/// never steps back a little while playing, and big differences (a seek,
/// a loop) jump at once.
class SmoothClock {
  int _anchorMs = 0;
  int _anchorAt = 0;
  int _lastReported = -1;
  bool _wasPlaying = false;
  int _shown = 0;
  bool _started = false;

  /// Differences bigger than this are a jump (seek / loop).
  static const int jumpMs = 300;

  /// Part of a small difference that is corrected on each player update.
  static const double follow = 0.25;

  /// [reported] = the player's position, [playing] = is it playing,
  /// [nowMs] = a steady clock (for example a Ticker's elapsed time).
  int position({
    required int reported,
    required bool playing,
    required int nowMs,
    double speed = 1,
  }) {
    if (!playing || !_started || !_wasPlaying) {
      _wasPlaying = playing;
      _started = true;
      _anchor(reported, nowMs);
      _lastReported = reported;
      _shown = reported;
      return reported;
    }
    final predicted = _anchorMs + ((nowMs - _anchorAt) * speed).round();
    if (reported != _lastReported) {
      _lastReported = reported;
      final err = reported - predicted;
      if (err.abs() > jumpMs) {
        _anchor(reported, nowMs);
        _shown = reported;
        return reported;
      }
      _anchorMs += (err * follow).round();
    }
    var p = _anchorMs + ((nowMs - _anchorAt) * speed).round();
    // never a small step back (that is the shaking)
    if (p < _shown && _shown - p < jumpMs) p = _shown;
    _shown = p;
    return p;
  }

  /// Forget the past (after the user moved the video).
  void reset() {
    _started = false;
    _wasPlaying = false;
    _lastReported = -1;
  }

  void _anchor(int ms, int at) {
    _anchorMs = ms;
    _anchorAt = at;
  }
}
