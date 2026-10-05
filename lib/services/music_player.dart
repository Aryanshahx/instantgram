import 'package:video_player/video_player.dart';

import '../models/music.dart';
import 'epidemic_service.dart';

/// Plays one of the app's own tracks (looping). The native video player can play audio files
/// too, so no extra plugin is needed. It mixes with other sounds instead of taking over audio
/// focus, so a clip's own sound and the music can play together.
class MusicPlayer {
  MusicPlayer(this.track);

  final MusicTrack track;
  VideoPlayerController? _c;
  bool _disposed = false;
  bool get ready => _c != null && _c!.value.isInitialized && !_disposed;

  Future<void> init({double volume = 1}) async {
    final opts = VideoPlayerOptions(mixWithOthers: true);
    VideoPlayerController c;
    try {
      c = track.remote
          ? VideoPlayerController.networkUrl(
              Uri.parse(await EpidemicService.instance.audioUrl(track)),
              videoPlayerOptions: opts,
            )
          : VideoPlayerController.asset(track.asset, videoPlayerOptions: opts);
    } catch (_) {
      return; // no link: the track stays silent
    }
    try {
      await c.initialize();
      await c.setLooping(true);
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

  Future<void> play() async {
    if (ready) await _c!.play();
  }

  Future<void> pause() async {
    if (ready) await _c!.pause();
  }

  Future<void> restart() async {
    if (ready) await _c!.seekTo(Duration.zero);
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
