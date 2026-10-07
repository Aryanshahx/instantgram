import 'dart:io';

import 'package:flutter/services.dart';

import '../core/errors.dart';

/// The command that does the same on a computer (used to check the result by hand, see
/// `tools/merge_audio.sh`):
///
/// ```text
/// ffmpeg -y -i video.mp4 -i song.m4a -map 0:v:0 -map 1:a:0 -c:v copy -c:a copy \
///        -t 30 -shortest -movflags +faststart out.mp4
/// ```
///
/// * `-map 0:v:0 -map 1:a:0`  the picture of the video and the sound of the song only, so the
///   original sound is dropped;
/// * `-c:v copy -c:a copy`    nothing is re-encoded (no quality loss, a few hundred ms);
/// * `-t 30 -shortest`        the result is never longer than 30 s and ends with the shorter of
///   video and song: a short video cuts the song, a long video is cut at the end of the song;
/// * `-movflags +faststart`   plays at once when streamed.
const String kFfmpegMergeCommand =
    'ffmpeg -y -i video.mp4 -i song.m4a -map 0:v:0 -map 1:a:0 -c:v copy -c:a copy '
    '-t 30 -shortest -movflags +faststart out.mp4';

/// The length a merged video gets: the shortest of the video, the song and [cap].
double mergedSeconds({
  required double video,
  required double song,
  double cap = 30,
}) {
  var s = cap;
  if (video > 0 && video < s) s = video;
  if (song > 0 && song < s) s = song;
  return s;
}

class MergeResult {
  const MergeResult(this.file, this.seconds);
  final File file;
  final double seconds;
}

/// Puts a song under a video on the phone itself. On Android this uses the system's MediaMuxer
/// (the local `packages/audio_merge` plugin): no cloud, no extra library, no re-encoding.
class AudioMerger {
  AudioMerger._();

  static const MethodChannel _channel = MethodChannel(
    'com.hypertechlabs.audio_merge',
  );

  /// Tests replace this: (video, audio, output, maxSeconds) -> seconds written.
  static Future<double> Function(
    String video,
    String audio,
    String output,
    double maxSeconds,
  )?
  backend;

  /// Merges [audio] (an AAC .m4a) into [video]; the sound of the video is replaced.
  static Future<MergeResult> merge({
    required File video,
    required File audio,
    double maxSeconds = 30,
  }) async {
    final out = File(
      '${Directory.systemTemp.path}/instantgram_song_${DateTime.now().microsecondsSinceEpoch}.mp4',
    );
    try {
      final b = backend;
      final double seconds;
      if (b != null) {
        seconds = await b(video.path, audio.path, out.path, maxSeconds);
      } else {
        final r = await _channel.invokeMapMethod<String, Object?>('merge', {
          'video': video.path,
          'audio': audio.path,
          'output': out.path,
          'maxSeconds': maxSeconds,
        });
        final s = r?['seconds'];
        seconds = s is num ? s.toDouble() : 0;
      }
      return MergeResult(out, seconds);
    } on PlatformException catch (e) {
      throw MediaException(
        e.message ?? 'Could not put the song into the video.',
      );
    } on MissingPluginException {
      throw const MediaException(
        'Putting a song into a video is not available here.',
      );
    }
  }
}
