import 'config.dart' show kMaxVideoSeconds;

/// True when a video of [ms] milliseconds is longer than one minute (a few hundredths
/// of rounding slack are allowed, because phones report 60.02 s for a "1 minute" video).
bool isVideoTooLong(int ms) => ms > kMaxVideoSeconds * 1000 + 300;

/// The message shown when a picked video is longer than one minute.
String videoTooLongMessage(int ms) {
  final s = (ms / 1000).round();
  final shown = '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  return 'A video can be at most 1 minute long. This one is $shown. Pick a shorter video.';
}

/// A video with a hit song (Apple preview) is cut to the length of the preview.
const int kSongPreviewSeconds = 30;
