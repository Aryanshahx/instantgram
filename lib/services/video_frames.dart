import 'dart:io';
import 'dart:math' as math;

/// video_compress takes the frame position in milliseconds on iOS, but Android hands the
/// number straight to MediaMetadataRetriever, which counts microseconds: without this
/// every "frame" on Android was the first one.
bool debugFramesInMicros = Platform.isAndroid;

int framePosition(int ms) {
  final v = debugFramesInMicros ? ms * 1000 : ms;
  return math.min(math.max(0, v), 0x7FFFFFFF);
}
