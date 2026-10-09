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

  /// Tests replace this: (input, output, maxSeconds) -> seconds written.
  static Future<double> Function(
    String input,
    String output,
    double maxSeconds,
  )?
  convertBackend;

  /// Turns any audio file the phone can play (mp3, m4a, wav, ogg, flac...) into a small AAC
  /// file (in an .mp4 container), keeping the first [maxSeconds] seconds. A file that already
  /// is AAC is copied without re-encoding.
  static Future<MergeResult> toAac({
    required File input,
    double maxSeconds = 60,
  }) async {
    final out = File(
      '${Directory.systemTemp.path}/instantgram_sound_${DateTime.now().microsecondsSinceEpoch}.mp4',
    );
    try {
      final b = convertBackend;
      final double seconds;
      if (b != null) {
        seconds = await b(input.path, out.path, maxSeconds);
      } else {
        final r = await _channel.invokeMapMethod<String, Object?>('toAac', {
          'input': input.path,
          'output': out.path,
          'maxSeconds': maxSeconds,
        });
        final s = r?['seconds'];
        seconds = s is num ? s.toDouble() : 0;
      }
      return MergeResult(out, seconds);
    } on PlatformException catch (e) {
      throw MediaException(
        e.message ?? 'Could not use that audio file. Try another one.',
      );
    } on MissingPluginException {
      throw const MediaException('Importing audio is not available here.');
    }
  }

  /// Tests replace this: gets the arguments of [mix] as a map, returns seconds written.
  static Future<double> Function(Map<String, Object?> args)? mixBackend;

  /// Builds the sound of a clip and writes it under the picture of [video] (see AudioMixer
  /// in the plugin): the [song] from [songStart] at [songVolume] with fades, the video's own
  /// sound at [originalVolume] (0 = left out) and a [voice] recording at [voiceVolume].
  /// [speed] stretches the picture (the sound keeps its speed); [turns] rotates it by quarter
  /// turns. With [cutToSong] the clip ends with the song (30 second previews).
  static Future<MergeResult> mix({
    required File video,
    File? song,
    double songStart = 0,
    double songVolume = 1,
    double originalVolume = 0,
    File? voice,
    double voiceVolume = 1,
    double fadeIn = 0,
    double fadeOut = 0,
    double speed = 1,
    int turns = 0,
    double maxSeconds = 60,
    bool cutToSong = true,
  }) async {
    final out = File(
      '${Directory.systemTemp.path}/instantgram_mix_${DateTime.now().microsecondsSinceEpoch}.mp4',
    );
    final args = <String, Object?>{
      'video': video.path,
      'output': out.path,
      'song': song?.path,
      'songStart': songStart,
      'songGain': songVolume,
      'origGain': originalVolume,
      'voice': voice?.path,
      'voiceGain': voiceVolume,
      'fadeIn': fadeIn,
      'fadeOut': fadeOut,
      'speed': speed,
      'turns': turns % 4,
      'maxSeconds': maxSeconds,
      'cutToSong': cutToSong && song != null,
    };
    try {
      final b = mixBackend;
      final double seconds;
      if (b != null) {
        seconds = await b(args);
      } else {
        final r = await _channel.invokeMapMethod<String, Object?>('mix', args);
        final s = r?['seconds'];
        seconds = s is num ? s.toDouble() : 0;
      }
      return MergeResult(out, seconds);
    } on PlatformException catch (e) {
      throw MediaException(e.message ?? 'Could not mix the sound of the clip.');
    } on MissingPluginException {
      throw const MediaException('Mixing sound is not available here.');
    }
  }

  /// Tests replace this: (inputs, output) -> seconds written.
  static Future<double> Function(List<String> inputs, String output)?
  joinBackend;

  /// Joins the parts left after Split into one clip (no re-encoding).
  static Future<MergeResult> join(List<File> parts) async {
    final out = File(
      '${Directory.systemTemp.path}/instantgram_join_${DateTime.now().microsecondsSinceEpoch}.mp4',
    );
    final inputs = [for (final p in parts) p.path];
    try {
      final b = joinBackend;
      final double seconds;
      if (b != null) {
        seconds = await b(inputs, out.path);
      } else {
        final r = await _channel.invokeMapMethod<String, Object?>('join', {
          'inputs': inputs,
          'output': out.path,
        });
        final s = r?['seconds'];
        seconds = s is num ? s.toDouble() : 0;
      }
      return MergeResult(out, seconds);
    } on PlatformException catch (e) {
      throw MediaException(
        e.message ?? 'Could not join the parts of the clip.',
      );
    } on MissingPluginException {
      throw const MediaException('Split is not available here.');
    }
  }

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
