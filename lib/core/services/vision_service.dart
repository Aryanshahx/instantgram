import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../shared/widgets/face_effects.dart';

/// v0.0.1 effects: face effects + green screen with Google ML Kit
/// (android/.../VisionChannel.kt). The models are not inside the app:
/// Google Play services downloads them the first time (see [install]).
class VisionService {
  VisionService._();
  static final VisionService instance = VisionService._();

  static const MethodChannel channel = MethodChannel('instantgram/vision');

  /// Download / video progress 0..100 (null = nothing running).
  final ValueNotifier<int?> progress = ValueNotifier<int?>(null);

  bool _listening = false;
  final Set<String> _ready = {};

  void _listen() {
    if (_listening) return;
    _listening = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'progress' && call.arguments is Map) {
        final p = (call.arguments as Map)['p'];
        if (p is int) progress.value = p.clamp(0, 100);
      }
      return null;
    });
  }

  /// Tests.
  @visibleForTesting
  void debugReset() {
    _ready.clear();
    _listening = false;
    progress.value = null;
  }

  static String _key(bool segment) => segment ? 'face+segment' : 'face';

  /// Are the models on this phone?
  Future<bool> isReady({bool segment = false}) async {
    if (_ready.contains(_key(segment))) return true;
    try {
      final ok = await channel.invokeMethod<bool>('status', {
        'segment': segment,
      });
      if (ok == true) _ready.add(_key(segment));
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  /// Downloads the models (once). Throws [VisionException].
  Future<void> install({bool segment = false}) async {
    if (await isReady(segment: segment)) return;
    _listen();
    progress.value = 0;
    try {
      final ok = await channel.invokeMethod<bool>('install', {
        'segment': segment,
      });
      if (ok != true) throw const VisionException('Download failed');
      _ready.add(_key(segment));
      if (segment) _ready.add(_key(false));
    } on PlatformException catch (e) {
      throw VisionException(_why(e.message));
    } on MissingPluginException {
      throw const VisionException('Effects are not available on this phone');
    } finally {
      progress.value = null;
    }
  }

  static String _why(String? m) {
    final s = (m ?? '').toLowerCase();
    if (s.contains('network') || s.contains('internet')) {
      return 'No internet. Connect and try again.';
    }
    if (s.contains('play services') || s.contains('api_unavailable')) {
      return 'Effects need Google Play services';
    }
    return "Couldn't download effects. Try again.";
  }

  /// Looks at one small camera frame (NV21, see [shrinkNv21]).
  Future<VisionFrame?> analyze(
    Nv21Frame f, {
    required int rotation,
    required bool mirror,
    required bool face,
    required bool segment,
  }) async {
    final m = await channel.invokeMapMethod<String, dynamic>('analyze', {
      'bytes': f.bytes,
      'w': f.width,
      'h': f.height,
      'rotation': rotation,
      'mirror': mirror,
      'face': face,
      'segment': segment,
    });
    return m == null ? null : VisionFrame.fromMap(m);
  }

  /// A photo: upright copy + faces + (green screen) the person's mask.
  Future<VisionFrame> photo(
    String path, {
    required bool face,
    required bool segment,
  }) async {
    final m = await channel.invokeMapMethod<String, dynamic>('photo', {
      'path': path,
      'face': face,
      'segment': segment,
    });
    if (m == null) throw const VisionException('No photo');
    return VisionFrame.fromMap(m);
  }

  /// Finds the face in a filmed video (null = cancelled or no face).
  Future<String?> videoTrack(
    String path, {
    int fps = 6,
    int maxFrames = 240,
  }) async {
    _listen();
    progress.value = 0;
    try {
      final m = await channel.invokeMapMethod<String, dynamic>('video', {
        'path': path,
        'fps': fps,
        'maxFrames': maxFrames,
      });
      if (m == null || m['cancelled'] == true) return null;
      final t = m['track'];
      if (t is! String) return null;
      final track = FaceTrack.parse(t);
      return track != null && track.hasFace ? t : null;
    } finally {
      progress.value = null;
    }
  }

  Future<void> cancelVideo() async {
    try {
      await channel.invokeMethod<void>('cancelVideo');
    } catch (_) {}
  }
}

class VisionException implements Exception {
  const VisionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What ML Kit found in a picture [width] x [height] (upright).
class VisionFrame {
  const VisionFrame({
    required this.width,
    required this.height,
    this.faces = const [],
    this.mask,
    this.maskWidth = 0,
    this.maskHeight = 0,
    this.path = '',
  });

  final int width;
  final int height;
  final List<FaceBox> faces;

  /// One byte per pixel (255 = the person), [maskWidth] x [maskHeight].
  final Uint8List? mask;
  final int maskWidth;
  final int maskHeight;

  /// Photos: the upright copy.
  final String path;

  static int _i(Object? v) => v is num ? v.toInt() : 0;

  factory VisionFrame.fromMap(Map<String, dynamic> m) {
    final faces = m['faces'];
    final mask = m['mask'];
    final mw = _i(m['mw']), mh = _i(m['mh']);
    final okMask = mask is Uint8List && mw > 0 && mh > 0 && mask.length >= mw * mh;
    return VisionFrame(
      width: _i(m['w']),
      height: _i(m['h']),
      faces: faces is List
          ? faces.map(FaceBox.fromMap).whereType<FaceBox>().toList()
          : const [],
      mask: okMask ? mask : null,
      maskWidth: okMask ? mw : 0,
      maskHeight: okMask ? mh : 0,
      path: m['path'] is String ? m['path'] as String : '',
    );
  }
}

/// A camera frame in NV21 (Y plane, then V/U pairs).
class Nv21Frame {
  const Nv21Frame(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final int width;
  final int height;
}

/// Makes a camera frame small (short side about [target] pixels) so it
/// is fast to send and to look at. [src] = NV21 [w] x [h], rows [stride]
/// bytes long.
Nv21Frame? shrinkNv21(
  Uint8List src,
  int w,
  int h, {
  int? stride,
  int target = 240,
}) {
  final rs = stride ?? w;
  if (w < 2 || h < 2 || rs < w || src.length < rs * h + rs * (h ~/ 2)) {
    return null;
  }
  var step = (math.min(w, h) / target).floor();
  if (step < 1) step = 1;
  final w2 = (w ~/ step) & ~1, h2 = (h ~/ step) & ~1;
  if (w2 < 2 || h2 < 2) return null;
  final out = Uint8List(w2 * h2 * 3 ~/ 2);
  for (var j = 0; j < h2; j++) {
    final sy = j * step * rs, oy = j * w2;
    for (var i = 0; i < w2; i++) {
      out[oy + i] = src[sy + i * step];
    }
  }
  final uv = rs * h, ouv = w2 * h2;
  for (var j = 0; j < h2 ~/ 2; j++) {
    final sy = uv + ((j * 2 * step) >> 1) * rs;
    final oy = ouv + j * w2;
    for (var i = 0; i < w2 ~/ 2; i++) {
      final sx = ((i * 2 * step) >> 1) << 1;
      out[oy + i * 2] = src[sy + sx];
      out[oy + i * 2 + 1] = src[sy + sx + 1];
    }
  }
  return Nv21Frame(out, w2, h2);
}

/// How much to turn a camera frame so it is upright on a phone held
/// straight ([sensor] = the camera's sensor orientation).
int frameRotation(int sensor, {required bool front, int device = 0}) =>
    front ? (sensor + device) % 360 : (sensor - device + 360) % 360;
