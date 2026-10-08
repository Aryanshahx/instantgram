import 'dart:async';

import '../models/audio_edits.dart';
import '../models/music.dart';
import 'music_player.dart';

/// Keeps a song and a voiceover in step with a video that is playing somewhere else (the
/// Create preview). Call [follow] with the video's position whenever the player reports;
/// after a loop or a seek call it with `force: true`.
///
/// The positions come from [songPositionFor], the same rule the clip is saved with, so what
/// you hear in the preview is what the posted clip sounds like.
class ClipSound {
  MusicPlayer? _song;
  MusicPlayer? _voice;
  AudioEdits _audio = AudioEdits.none;
  double _trimStart = 0;
  double _speed = 1;
  double _lastVideoSec = -1;
  DateTime _lastCheck = DateTime.fromMillisecondsSinceEpoch(0);
  bool _disposed = false;

  MusicPlayer? get song => _song;
  AudioEdits get audio => _audio;

  /// Sets the song (null = none), its edits and the clip's trim start and speed. A player
  /// is made again only when the song, its start point or the voiceover changed.
  Future<void> set({
    MusicTrack? track,
    AudioEdits audio = AudioEdits.none,
    double trimStart = 0,
    double speed = 1,
    double songVolumeScale = 1,
  }) async {
    final songChanged =
        track?.id != _song?.track.id || audio.songStart != _audio.songStart;
    final voiceChanged = audio.voicePath != _audio.voicePath;
    _audio = audio;
    _trimStart = trimStart;
    _speed = speed <= 0 ? 1 : speed;
    if (songChanged) {
      final old = _song;
      _song = null;
      await old?.dispose();
      if (track != null) {
        final p = MusicPlayer(track);
        await p.init(
          volume: audio.songVolume * songVolumeScale,
          startAt: audio.songStart,
        );
        if (_disposed || _audio.songStart != audio.songStart) {
          await p.dispose();
        } else {
          _song = p;
        }
      }
    } else {
      await _song?.setVolume(audio.songVolume * songVolumeScale);
    }
    if (voiceChanged) {
      final old = _voice;
      _voice = null;
      await old?.dispose();
      if (audio.hasVoice) {
        final v = MusicPlayer(
          MusicTrack.device(path: audio.voicePath, title: 'Voiceover'),
        );
        await v.init(volume: audio.voiceVolume, loop: false);
        if (_disposed || _audio.voicePath != audio.voicePath) {
          await v.dispose();
        } else {
          _voice = v;
        }
      }
    } else {
      await _voice?.setVolume(audio.voiceVolume);
    }
    _lastVideoSec = -1; // the next report puts everything in place
  }

  /// The video is at [videoSec] and [playing]. A jump backwards (the video looped) or
  /// [force] moves the sound at once; otherwise it is only corrected when it drifted.
  void follow(double videoSec, {required bool playing, bool force = false}) {
    if (_disposed) return;
    final looped = _lastVideoSec >= 0 && videoSec < _lastVideoSec - 0.3;
    final first = _lastVideoSec < 0;
    _lastVideoSec = videoSec;
    final now = DateTime.now();
    final due = now.difference(_lastCheck).inMilliseconds > 400;
    if (!(force || looped || first || due)) return;
    _lastCheck = now;
    final hard = force || looped || first;

    final s = _song;
    if (s != null && s.ready) {
      final want = songPositionFor(
        videoSec: videoSec,
        trimStart: _trimStart,
        songStart: _audio.songStart,
        speed: _speed,
        songLength: s.duration.inMilliseconds / 1000,
      );
      if (hard || songIsOff(s.position.inMilliseconds / 1000, want)) {
        unawaited(s.seekTo(Duration(milliseconds: (want * 1000).round())));
      }
      if (playing && !s.playing) unawaited(s.play());
      if (!playing && s.playing) unawaited(s.pause());
    }
    final v = _voice;
    if (v != null && v.ready) {
      final want = songPositionFor(
        videoSec: videoSec,
        trimStart: _trimStart,
        speed: _speed,
      );
      final len = v.duration.inMilliseconds / 1000;
      if (!playing || (len > 0 && want >= len)) {
        if (v.playing) unawaited(v.pause());
      } else {
        if (hard || songIsOff(v.position.inMilliseconds / 1000, want)) {
          unawaited(v.seekTo(Duration(milliseconds: (want * 1000).round())));
        }
        if (!v.playing) unawaited(v.play());
      }
    }
  }

  /// Plays or pauses the song alone (photos: there is no video to follow).
  Future<void> playAlone(bool play) async {
    final s = _song;
    if (s == null) return;
    play ? await s.play() : await s.pause();
  }

  Future<void> pause() async {
    await _song?.pause();
    await _voice?.pause();
  }

  Future<void> dispose() async {
    _disposed = true;
    final s = _song;
    final v = _voice;
    _song = null;
    _voice = null;
    await s?.dispose();
    await v?.dispose();
  }
}
