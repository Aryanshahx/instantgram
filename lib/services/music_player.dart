import 'dart:io';

import 'package:video_player/video_player.dart';

import '../models/music.dart';
import 'itunes_service.dart';
import 'online_music_service.dart';

/// Plays a track (looping): a file from the phone, an uploaded one, a song from the internet or
/// one of the app's old built-in loops. The native video player can play audio files
/// too, so no extra plugin is needed. It mixes with other sounds instead of taking over audio
/// focus, so a clip's own sound and the music can play together.
class MusicPlayer {
  MusicPlayer(this.track);

  final MusicTrack track;
  VideoPlayerController? _c;
  bool _disposed = false;
  bool get ready => _c != null && _c!.value.isInitialized && !_disposed;

  /// Where the track starts (seconds) and where it starts again after the end.
  double _startAt = 0;
  bool _wrapping = false;

  /// Where the track is now (zero before it is ready).
  Duration get position => ready ? _c!.value.position : Duration.zero;

  /// Length of the track (zero when unknown).
  Duration get duration => ready ? _c!.value.duration : Duration.zero;

  bool get playing => ready && _c!.value.isPlaying;

  /// [startAt] = seconds into the track where it begins, and where it begins again after
  /// its end (the part of the song chosen in the editor).
  /// [loop] false = plays once and stops at the end (a voiceover).
  Future<void> init({
    double volume = 1,
    double startAt = 0,
    bool loop = true,
  }) async {
    _startAt = startAt < 0 ? 0 : startAt;
    final opts = VideoPlayerOptions(mixWithOthers: true);
    VideoPlayerController c;
    try {
      c = track.isLocal
          ? VideoPlayerController.file(
              File(track.localPath),
              videoPlayerOptions: opts,
            )
          : track.isDevice
          ? VideoPlayerController.networkUrl(
              Uri.parse(track.uploadedUrl),
              videoPlayerOptions: opts,
            )
          : track.remote
          ? VideoPlayerController.networkUrl(
              Uri.parse(
                track.isApple
                    ? await ItunesService.instance.previewUrl(track)
                    : await OnlineMusicService.instance.audioUrl(track),
              ),
              videoPlayerOptions: opts,
            )
          : VideoPlayerController.asset(track.asset, videoPlayerOptions: opts);
    } catch (_) {
      return; // no link: the track stays silent
    }
    try {
      await c.initialize();
      final len = c.value.duration.inMilliseconds / 1000;
      if (len > 0 && _startAt >= len - 0.5) {
        _startAt = 0; // past the end: from the start
      }
      // From the start the player loops by itself; from a chosen point it is sent back there.
      await c.setLooping(loop && _startAt == 0);
      if (_startAt > 0) {
        await c.seekTo(Duration(milliseconds: (_startAt * 1000).round()));
      }
      if (loop && _startAt > 0) c.addListener(() => _wrap(c));
      await c.setVolume(volume.clamp(0.0, 1.0));
    } catch (_) {
      await c.dispose();
      return;
    }
    if (_disposed) {
      await c.dispose();
      return;
    }
    _c = c;
  }

  /// At the end of the track: back to the chosen start, and on.
  void _wrap(VideoPlayerController c) {
    final v = c.value;
    if (_wrapping || _disposed || !v.isInitialized) return;
    final end = v.duration - const Duration(milliseconds: 120);
    if (v.duration > Duration.zero && v.position >= end) {
      _wrapping = true;
      c
          .seekTo(Duration(milliseconds: (_startAt * 1000).round()))
          .then((_) => c.play())
          .whenComplete(() => _wrapping = false);
    }
  }

  /// Moves the track to [to] (kept inside the track).
  Future<void> seekTo(Duration to) async {
    if (!ready) return;
    final len = _c!.value.duration;
    var t = to < Duration.zero ? Duration.zero : to;
    if (len > Duration.zero && t >= len) {
      t = Duration(milliseconds: (_startAt * 1000).round());
    }
    await _c!.seekTo(t);
  }

  Future<void> play() async {
    if (ready) await _c!.play();
  }

  Future<void> pause() async {
    if (ready) await _c!.pause();
  }

  Future<void> restart() async {
    if (ready) {
      await _c!.seekTo(Duration(milliseconds: (_startAt * 1000).round()));
    }
  }

  Future<void> setVolume(double v) async {
    if (ready) await _c!.setVolume(v.clamp(0.0, 1.0));
  }

  Future<void> setSpeed(double s) async {
    if (ready) await _c!.setPlaybackSpeed(s);
  }

  Future<void> dispose() async {
    _disposed = true;
    final c = _c;
    _c = null;
    await c?.dispose();
  }
}
