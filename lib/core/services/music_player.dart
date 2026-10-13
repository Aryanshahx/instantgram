import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';

/// Plays the music of ONE post / clip at a time, in a loop.
/// The owner (usually a post id) starts it when the post is on screen and
/// stops it when the post leaves the screen.
class MusicPlayer with WidgetsBindingObserver {
  MusicPlayer._();
  static final MusicPlayer instance = MusicPlayer._();

  /// Tests: never touch the real audio plugin.
  static bool disabled = false;

  AudioPlayer? _player;
  String? _owner;
  String? _source;
  double _volume = 1;
  bool _observing = false;
  bool _pausedByApp = false;

  /// Who is playing now (null = nothing).
  final ValueNotifier<String?> owner = ValueNotifier(null);

  bool isOwner(String id) => _owner == id;

  /// Plays [source] (an https URL or a file path) for [ownerId].
  Future<void> play(String ownerId, String source, {double volume = 1}) async {
    if (disabled || source.isEmpty) return;
    _volume = volume;
    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(this);
    }
    final p = _player ??= AudioPlayer(
      handleInterruptions: false,
      handleAudioSessionActivation: false,
    );
    if (_owner == ownerId && _source == source) {
      await p.setVolume(volume);
      if (!p.playing) p.play();
      return;
    }
    _owner = ownerId;
    _source = source;
    owner.value = ownerId;
    try {
      if (source.startsWith('http')) {
        await p.setUrl(source);
      } else {
        await p.setFilePath(source);
      }
      if (_owner != ownerId) return; // someone else started meanwhile
      await p.setLoopMode(LoopMode.one);
      await p.setVolume(volume);
      p.play(); // don't await: completes when playback stops
    } catch (e) {
      debugPrint('Music error: $e');
    }
  }

  /// Pauses (keeps the song) if [ownerId] is the one playing.
  void pause(String ownerId) {
    if (_owner != ownerId) return;
    _pausedByApp = false;
    _player?.pause();
  }

  /// Continues after [pause].
  void resume(String ownerId) {
    final p = _player;
    if (_owner != ownerId || p == null || p.playing) return;
    p.setVolume(_volume);
    p.play(); // don't await
  }

  Future<void> setVolume(double v) async {
    _volume = v;
    await _player?.setVolume(v);
  }

  /// Stops if [ownerId] is the one playing.
  Future<void> stop(String ownerId) async {
    if (_owner != ownerId) return;
    await stopAll();
  }

  Future<void> stopAll() async {
    _owner = null;
    _source = null;
    owner.value = null;
    try {
      await _player?.stop();
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final p = _player;
    if (p == null || _owner == null) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (p.playing) {
        _pausedByApp = true;
        p.pause();
      }
    } else if (state == AppLifecycleState.resumed && _pausedByApp) {
      _pausedByApp = false;
      p.setVolume(_volume);
      p.play();
    }
  }
}
