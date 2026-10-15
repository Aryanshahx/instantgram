import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// v0.14: tells Android "don't use the edge back swipe here" (the editor
/// timeline's trim handles). Android allows up to 200 dp per edge.
class GestureExclusion {
  GestureExclusion._();
  static final GestureExclusion instance = GestureExclusion._();

  static const MethodChannel _ch = MethodChannel('instantgram/system');

  /// Width of the strip at each screen edge (dp).
  static const double edge = 40;

  List<int>? _last;

  /// Strips at the left and right screen edges, as tall as [area] (global
  /// position, dp). Sent to Android in pixels.
  void set(
    Rect area, {
    required double screenWidth,
    required double devicePixelRatio,
  }) {
    final h = area.height.clamp(0.0, 200.0);
    final top = area.top;
    int p(double v) => (v * devicePixelRatio).round();
    final rects = <int>[
      0, p(top), p(edge), p(top + h), //
      p(screenWidth - edge), p(top), p(screenWidth), p(top + h),
    ];
    if (listEquals(rects, _last)) return;
    _last = rects;
    _send(rects);
  }

  void clear() {
    if (_last == null || _last!.isEmpty) return;
    _last = const [];
    _send(const []);
  }

  void _send(List<int> rects) {
    if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) return;
    _ch
        .invokeMethod<void>('gestureExclusion', {'rects': rects})
        .catchError((Object e) => debugPrint('gesture exclusion: $e'));
  }
}
