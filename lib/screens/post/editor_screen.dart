import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/finish.dart';
import '../../models/audio_edits.dart';
import '../../models/music.dart';
import '../../models/story.dart';
import '../../services/music_player.dart';
import '../../services/voice_recorder.dart';
import '../../services/overlay_painter.dart';
import '../../services/photo_edit.dart';
import '../../services/playhead.dart';
import '../../widgets/music_widgets.dart';
import '../../widgets/overlay_tools.dart';
import '../../widgets/edit_timeline.dart';
import 'photo_editor_screen.dart' show CropOverlay;
import 'video_editor_screen.dart' show VideoEdits;

/// What the editor hands back.
class EditorResult {
  const EditorResult({
    this.photoFile,
    this.photoEdits,
    this.videoEdits,
    this.look,
    this.overlays = const [],
    this.music,
    this.audio = AudioEdits.none,
  });

  /// Photos: the picture to upload (texts and stickers are burned in). Null for videos.
  final File? photoFile;

  /// Photos: crop / filter / adjust that were applied (null = none), to re-open the editor.
  final PhotoEdits? photoEdits;

  /// Videos: trim and mute (null = none).
  final VideoEdits? videoEdits;

  /// Videos: colour look shown while the clip plays (null = none).
  final VideoLook? look;

  /// Texts and stickers (photos: already burned into [photoFile], kept to edit again).
  final List<StoryOverlay> overlays;

  /// The audio track at the end of editing (null = none).
  final MusicTrack? music;

  /// Which part of the song, the volumes, fades and the voiceover.
  final AudioEdits audio;
}

/// One editing screen for photos and videos: audio, text, stickers, filters, adjust, and
/// crop (photos) or trim and mute (videos). Photos are saved with every change burned in;
/// videos keep their file and carry texts, stickers and the colour look next to it.
class EditorScreen extends StatefulWidget {
  const EditorScreen({
    super.key,
    required this.file,
    required this.video,
    this.thumb,
    this.photoEdits,
    this.videoEdits,
    this.look,
    this.overlays = const [],
    this.music,
    this.audio = AudioEdits.none,
    this.voiceover = true,
    this.maxSeconds,
  });

  /// The photo as it was picked, or the video.
  final File file;
  final bool video;

  /// A frame of the video (used for the filter previews).
  final File? thumb;
  final PhotoEdits? photoEdits;
  final VideoEdits? videoEdits;
  final VideoLook? look;
  final List<StoryOverlay> overlays;
  final MusicTrack? music;
  final AudioEdits audio;

  /// The Voiceover tool is offered (a single clip; not inside a post with several items).
  final bool voiceover;

  /// Longest part of a video that may be kept (null = no limit).
  final int? maxSeconds;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

enum _Tool { filters, adjust, crop, audio, speed }

class _EditorScreenState extends State<EditorScreen>
    with SingleTickerProviderStateMixin {
  // photo
  PhotoProxy? _proxy;
  // video
  VideoPlayerController? _c;
  int _total = 1;
  double _start = 0;
  double _end = 1;
  bool _mute = false;
  bool _paused = false;

  Object? _loadError;
  late PhotoEdits _e = _initialEdits();
  final List<StoryOverlay> _overlays = [];
  MusicTrack? _music;
  MusicPlayer? _player;

  // sound: which part of the song, volumes, fades, voiceover
  late AudioEdits _a = widget.audio;
  MusicPlayer? _voice; // plays the recorded voiceover in step with the video
  VoiceRecorder? _rec;
  bool _recording = false;
  DateTime _lastSync = DateTime.fromMillisecondsSinceEpoch(0);

  // video: speed and quarter turns
  double _speed = 1;
  int _turns = 0;
  // photos always have a tool open; videos keep the timeline in view and open a tool on demand
  _Tool? _tool = _Tool.filters;
  int _preset = 0; // index into _presets (0 = free)
  bool _busy = false;
  int? _sel; // the selected text or sticker
  final ValueNotifier<double> _pos = ValueNotifier(0);

  // the timeline is redrawn through these, not through setState of the whole editor
  final ValueNotifier<(double, double)> _rangeN = ValueNotifier((0, 1));
  final ValueNotifier<int> _ovTick = ValueNotifier(0);
  final PlayheadSmoother _smooth = PlayheadSmoother();
  final Stopwatch _clock = Stopwatch()..start();
  Ticker? _ticker; // made when a video is loaded (photos never need it)
  Ticker get _tk => _ticker ??= createTicker(_onFrame);
  late final SeekThrottle _seek = SeekThrottle((d) async => _c?.seekTo(d));
  bool _looping = false;
  final List<Uint8List?> _frames = List<Uint8List?>.filled(12, null);

  // timeline: the clip is selected (white frame with trim handles); playing before a scrub
  bool _videoSel = false;
  bool _playBeforeScrub = false;

  // undo / redo: a fingerprint of every edit; quick changes in a row are one step
  final List<_Snap> _undo = [];
  final List<_Snap> _redo = [];
  _Snap? _now;
  DateTime _lastChange = DateTime.fromMillisecondsSinceEpoch(0);
  bool _restoring = false;

  // every voiceover recorded here (undo can bring an older one back); unused ones are
  // removed when the editor closes
  final Set<String> _voiceFiles = {};
  String? _keptVoice;
  final ValueNotifier<int> _framesTick = ValueNotifier(0);

  static const _presets = <(String, double?)>[
    ('Free', null),
    ('Original', -1),
    ('1:1', 1),
    ('4:5', 4 / 5),
    ('9:16', 9 / 16),
    ('16:9', 16 / 9),
    ('3:4', 3 / 4),
  ];

  bool get _isVideo => widget.video;

  File? get _thumb => _isVideo ? widget.thumb : _proxy?.file;

  PhotoEdits _initialEdits() {
    if (!widget.video) return widget.photoEdits?.copy() ?? PhotoEdits();
    final l = widget.look;
    return PhotoEdits(
      filter: l?.filter ?? 0,
      brightness: l?.brightness ?? 0,
      contrast: l?.contrast ?? 1,
      saturation: l?.saturation ?? 1,
    );
  }

  @override
  void initState() {
    super.initState();
    _overlays.addAll(widget.overlays);
    _music = widget.music;
    if (_isVideo) {
      _tool = null;
      _loadVideo();
    } else {
      _loadPhoto();
    }
    // A video's song starts once the picture is ready, so both begin at the same moment.
    final m = _music;
    if (m != null && !_isVideo) unawaited(_startPlayer(m));
  }

  Future<void> _loadPhoto() async {
    try {
      final p = await PhotoEditor.makeProxy(widget.file);
      if (!mounted) {
        p.file.delete().ignore();
        return;
      }
      setState(() => _proxy = p);
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  Future<void> _loadVideo() async {
    final c = VideoPlayerController.file(
      widget.file,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      final total = (c.value.duration.inMilliseconds / 1000).ceil().clamp(
        1,
        1 << 20,
      );
      final init = widget.videoEdits;
      setState(() {
        _c = c;
        _total = total;
        _start = (init?.start ?? 0).toDouble().clamp(0, total - 1);
        _end = (init?.end ?? total).toDouble().clamp(
          _start + 1,
          total.toDouble(),
        );
        final cap = widget.maxSeconds;
        if (cap != null && _end - _start > cap) _end = _start + cap;
        _mute = init?.mute ?? false;
        _speed = init?.speed ?? 1;
        _turns = init?.turns ?? 0;
        _rangeN.value = (_start, _end);
      });
      _smooth.rate = _speed;
      await c.setLooping(false);
      await c.setVolume(_videoVolume);
      if (_speed != 1) await c.setPlaybackSpeed(_speed);
      c.addListener(_tick);
      unawaited(_loadFrames());
      await c.seekTo(Duration(seconds: _start.round()));
      _smooth.seek(_start, _clock.elapsed);
      _pos.value = _start;
      await c.play();
      final m = _music;
      if (m != null) unawaited(_startPlayer(m));
      if (_a.hasVoice) unawaited(_startVoice());
    } catch (e) {
      await c.dispose();
      if (mounted) setState(() => _loadError = e);
    }
  }

  /// The pictures of the timeline, one after the other.
  Future<void> _loadFrames() async {
    final n = _frames.length;
    for (var i = 0; i < n; i++) {
      if (!mounted) return;
      try {
        final b = await VideoCompress.getByteThumbnail(
          widget.file.path,
          quality: 40,
          position: ((i + 0.5) / n * _total * 1000).round(),
        );
        if (!mounted) return;
        _frames[i] = b;
        _framesTick.value++;
      } catch (_) {
        // that picture stays dark
      }
    }
  }

  /// The player reported (a few times a second): keep the smooth clock in step and loop.
  void _tick() {
    final c = _c;
    if (c == null) return;
    final v = c.value;
    final now = _clock.elapsed;
    _smooth.report(v.position.inMilliseconds / 1000, v.isPlaying, now);
    if (v.isPlaying && !_tk.isActive) {
      _tk.start();
    } else if (!v.isPlaying && _tk.isActive) {
      _tk.stop();
      _pos.value = _smooth.value(now);
    }
    if (_paused) return;
    final end = Duration(milliseconds: (_end * 1000).round());
    if (v.isInitialized &&
        (v.position >= end ||
            (v.position >= v.duration && v.duration > Duration.zero))) {
      _loopBack();
      return;
    }
    // a few times a second: the song and the voiceover must not drift away from the picture
    if (v.isPlaying &&
        DateTime.now().difference(_lastSync).inMilliseconds > 400) {
      _syncSound();
    }
  }

  /// One step per screen frame: the playhead moves smoothly between the player's reports.
  void _onFrame(Duration _) {
    final est = _smooth.value(_clock.elapsed);
    if (est >= _end - 0.02) {
      _loopBack();
      return;
    }
    _pos.value = est;
  }

  void _loopBack() {
    final c = _c;
    if (c == null || _looping) return;
    if (_recording) {
      // the voiceover covers the clip once: at its end the recording stops
      unawaited(_stopRecording());
      return;
    }
    _looping = true;
    _smooth.seek(_start, _clock.elapsed);
    _pos.value = _start;
    c
        .seekTo(Duration(milliseconds: (_start * 1000).round()))
        .then((_) => c.play())
        .whenComplete(() {
          _looping = false;
          _syncSound(force: true, at: _start);
        });
  }

  // ------------------------------------------------------- sound in step

  /// The video's own sound in the preview: off when muted; under a song or a voiceover it
  /// is at the chosen "original sound" level; at another speed it is left out (it would
  /// not match the picture any more).
  double get _videoVolume {
    if (_mute || _speed != 1) return 0;
    if (_music != null || _a.hasVoice) return _a.originalVolume;
    return 1;
  }

  /// Puts the song and the voiceover where they belong for the picture. [at] = the video
  /// position (seconds) when it is known better than the player's report (right after a
  /// seek). [force] moves them even when they are only a little off.
  void _syncSound({bool force = false, double? at}) {
    _lastSync = DateTime.now();
    final c = _c;
    if (!_isVideo || c == null) return;
    final videoSec = at ?? c.value.position.inMilliseconds / 1000;
    final p = _player;
    if (p != null && p.ready) {
      final len = p.duration.inMilliseconds / 1000;
      final want = songPositionFor(
        videoSec: videoSec,
        trimStart: _start,
        songStart: _a.songStart,
        speed: _speed,
        songLength: len,
      );
      final now = p.position.inMilliseconds / 1000;
      if (force || songIsOff(now, want)) {
        p.seekTo(Duration(milliseconds: (want * 1000).round()));
      }
    }
    final v = _voice;
    if (v != null && v.ready && !_recording) {
      final want = songPositionFor(
        videoSec: videoSec,
        trimStart: _start,
        speed: _speed,
      );
      final len = v.duration.inMilliseconds / 1000;
      if (len > 0 && want >= len) {
        v.pause(); // the voiceover is over for this round
      } else {
        final now = v.position.inMilliseconds / 1000;
        if (force || songIsOff(now, want)) {
          v.seekTo(Duration(milliseconds: (want * 1000).round()));
        }
        if (!_paused && c.value.isPlaying && !v.playing) v.play();
      }
    }
  }

  @override
  void dispose() {
    _c?.removeListener(_tick);
    _ticker?.dispose();
    _seek.dispose();
    _pos.dispose();
    _rangeN.dispose();
    _ovTick.dispose();
    _framesTick.dispose();
    _c?.dispose();
    _player?.dispose();
    _voice?.dispose();
    _rec?.dispose();
    _proxy?.file.delete().ignore();
    for (final f in _voiceFiles) {
      if (f != _keptVoice && f != widget.audio.voicePath) {
        File(f).delete().ignore();
      }
    }
    super.dispose();
  }

  // ------------------------------------------------------------------- audio

  Future<void> _startPlayer(MusicTrack t) async {
    final old = _player;
    _player = null;
    await old?.dispose();
    final p = MusicPlayer(t);
    await p.init(volume: _a.songVolume, startAt: _a.songStart);
    if (!mounted || _music?.id != t.id) {
      await p.dispose();
      return;
    }
    _player = p;
    await _c?.setVolume(_videoVolume);
    _syncSound(force: true);
    if (!_paused && !_recording) await p.play();
  }

  /// The recorded voiceover, played in step with the picture.
  Future<void> _startVoice() async {
    final old = _voice;
    _voice = null;
    await old?.dispose();
    if (!_a.hasVoice) return;
    final path = _a.voicePath;
    final v = MusicPlayer(MusicTrack.device(path: path, title: 'Voiceover'));
    await v.init(volume: _a.voiceVolume, loop: false);
    if (!mounted || _a.voicePath != path) {
      await v.dispose();
      return;
    }
    _voice = v; // plays once per round of the clip (it does not loop by itself)
    _syncSound(force: true);
    if (!_paused) await v.play();
  }

  Future<void> _audio() async {
    // everything stops while the audio sheet is open (its previews play on their own)
    final wasPaused = _paused;
    _c?.pause();
    _player?.pause();
    _voice?.pause();
    final t = await pickMusic(context, current: _music);
    if (!mounted) return;
    if (t != null) {
      setState(() {
        if (t.id != _music?.id) _a = _a.copyWith(songStart: 0);
        _music = t;
      });
      await _startPlayer(t);
    }
    if (!wasPaused && !_recording) {
      await _c?.play();
      if (!_isVideo) _player?.play();
      _syncSound(force: true);
    }
  }

  Future<void> _removeAudio() async {
    final old = _player;
    _player = null;
    setState(() {
      _music = null;
      _a = _a.copyWith(songStart: 0, fadeIn: 0, fadeOut: 0, songVolume: 1);
      if (_tool == _Tool.audio && !_isVideo) _tool = _Tool.filters;
    });
    await old?.dispose();
    await _c?.setVolume(_videoVolume);
  }

  // --------------------------------------------------------- audio tools

  /// The song starts at [sec] (seconds into the song).
  void _setSongStart(double sec) {
    setState(() => _a = _a.copyWith(songStart: sec));
    if (_isVideo) {
      _syncSound(force: true);
    } else {
      _player?.seekTo(Duration(milliseconds: (sec * 1000).round()));
    }
  }

  /// A new start point: the player is made again so it also starts there after its end.
  Future<void> _songStartDone() async {
    final m = _music;
    if (m != null) await _startPlayer(m);
  }

  void _setSongVolume(double v) {
    setState(() => _a = _a.copyWith(songVolume: v));
    _player?.setVolume(v);
  }

  void _setOriginalVolume(double v) {
    setState(() => _a = _a.copyWith(originalVolume: v));
    _c?.setVolume(_videoVolume);
  }

  void _setVoiceVolume(double v) {
    setState(() => _a = _a.copyWith(voiceVolume: v));
    _voice?.setVolume(v);
  }

  // ------------------------------------------------------------ voiceover

  /// Records over the clip from its first second: the video plays silently so the phone's
  /// microphone only hears you, and the recording stops at the end of the clip.
  Future<void> _recordVoice() async {
    if (_recording) {
      await _stopRecording();
      return;
    }
    final c = _c;
    if (c == null) return;
    final rec = _rec ??= VoiceRecorder();
    _player?.pause();
    _voice?.pause();
    await c.pause();
    await c.setVolume(0);
    await c.seekTo(Duration(milliseconds: (_start * 1000).round()));
    _smooth.seek(_start, _clock.elapsed);
    _pos.value = _start;
    try {
      await rec.start();
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
      await c.setVolume(_videoVolume);
      return;
    }
    if (!mounted) return;
    setState(() {
      _recording = true;
      _paused = false;
    });
    await c.play();
  }

  Future<void> _stopRecording() async {
    final rec = _rec;
    if (!_recording || rec == null) return;
    setState(() => _recording = false);
    final r = await rec.stop();
    final c = _c;
    if (c != null) {
      await c.pause();
      await c.seekTo(Duration(milliseconds: (_start * 1000).round()));
      _smooth.seek(_start, _clock.elapsed);
      _pos.value = _start;
    }
    if (!mounted) return;
    if (r == null) {
      showToast(context, 'Nothing was recorded. Try again.');
    } else {
      _voiceFiles.add(r.file.path);
      setState(() => _a = _a.copyWith(voicePath: r.file.path));
    }
    await c?.setVolume(_videoVolume);
    await _startVoice();
    if (!_paused) {
      await c?.play();
      _player?.play();
      _syncSound(force: true, at: _start);
    }
  }

  Future<void> _deleteVoice() async {
    final v = _voice;
    _voice = null;
    setState(() => _a = _a.withoutVoice());
    await v?.dispose();
    await _c?.setVolume(_videoVolume);
  }

  // ---------------------------------------------------------- speed, turn

  Future<void> _setSpeed(double s) async {
    setState(() => _speed = s);
    _smooth.rate = s;
    final c = _c;
    if (c == null) return;
    await c.setPlaybackSpeed(s);
    await c.setVolume(_videoVolume);
    _syncSound(force: true);
  }

  void _turnVideo() => setState(() => _turns = (_turns + 1) % 4);

  // ------------------------------------------------------------ text, stickers

  Future<void> _addText() async {
    final r = await showOverlayTextSheet(context, const StoryOverlay(text: ''));
    if (r == null || r.text.trim().isEmpty || !mounted) return;
    setState(() => _overlays.add(r.copyWith(dx: 0.5, dy: 0.45)));
  }

  Future<void> _addSticker() async {
    final o = await showStickerSheet(context);
    if (o == null || !mounted) return;
    setState(() {
      _overlays.add(o);
      _sel = _overlays.length - 1;
    });
  }

  /// First tap selects (frame, handle, size bar); a second tap on a selected text edits it.
  Future<void> _tapOverlay(int i) async {
    if (_sel != i) {
      setState(() => _sel = i);
      return;
    }
    if (!_overlays[i].emoji && !_overlays[i].isImage) await _editSelected();
  }

  Future<void> _editSelected() async {
    final i = _sel;
    if (i == null || i >= _overlays.length) return;
    final o = _overlays[i];
    if (o.emoji || o.isImage) return;
    final r = await showOverlayTextSheet(context, o, canDelete: true);
    if (r == null || !mounted) return;
    setState(() {
      if (r.text.isEmpty) {
        _overlays.removeAt(i);
        _sel = null;
      } else {
        _overlays[i] = r;
      }
    });
  }

  void _deleteSelected() {
    final i = _sel;
    if (i == null || i >= _overlays.length) return;
    setState(() {
      _overlays.removeAt(i);
      _sel = null;
    });
  }

  void _resizeSelected(double scale) {
    final i = _sel;
    if (i == null || i >= _overlays.length) return;
    setState(() {
      _overlays[i] = _overlays[i].copyWith(scale: scale.clamp(0.4, 4.0));
    });
  }

  /// Size slider, smaller / bigger, edit and delete for the selected text or sticker.
  Widget _selectionBar() {
    final i = _sel;
    if (i == null || i >= _overlays.length) return const SizedBox.shrink();
    final o = _overlays[i];
    return OverlaySelectionBar(
      overlay: o,
      onScale: _resizeSelected,
      onEdit: !o.emoji && !o.isImage ? _editSelected : null,
      onDelete: _deleteSelected,
      onDone: () => setState(() => _sel = null),
    );
  }

  // ------------------------------------------------------------------ video

  void _togglePause() {
    final c = _c;
    if (c == null) return;
    setState(() => _paused = !_paused);
    if (_paused) {
      c.pause();
      _player?.pause();
      _voice?.pause();
    } else {
      c.play();
      _player?.play();
      _syncSound(force: true);
    }
  }

  Future<void> _toggleMute() async {
    setState(() => _mute = !_mute);
    await _c?.setVolume(_videoVolume);
  }

  void _applyRange(double s, double e, bool startMoved) {
    _start = s.clamp(0, _total - 1).toDouble();
    _end = e.clamp(_start + 1, _total.toDouble()).toDouble();
    _rangeN.value = (_start, _end);
    _noteChange();
    // the picture follows the handle that is being moved
    _scrubTo(startMoved ? _start : _end - 1);
  }

  /// Moves the picture (and the playhead) to [sec] without flooding the player with seeks.
  void _scrubTo(double sec) {
    _smooth.seek(sec, _clock.elapsed);
    _pos.value = sec;
    _seek.request(Duration(milliseconds: (sec * 1000).round()));
    _syncSound(force: true, at: sec);
  }

  void _rotate(int dir) {
    setState(() {
      _e.turns = (_e.turns + dir) % 4;
      if (_e.turns < 0) _e.turns += 4;
      _e.crop = const Rect.fromLTWH(0, 0, 1, 1);
      _preset = 0;
    });
  }

  void _flip() {
    setState(() {
      _e.flip = !_e.flip;
      final c = _e.crop;
      _e.crop = Rect.fromLTWH(1 - c.left - c.width, c.top, c.width, c.height);
    });
  }

  void _pickPreset(int i) {
    setState(() {
      _preset = i;
      final v = _presets[i].$2;
      if (v == null) return;
      _e.crop = PhotoEditor.cropFor(_photoAspect, v < 0 ? _photoAspect : v);
    });
  }

  // ------------------------------------------------------------ undo, redo

  _Snap _snap() => _Snap(
    start: _start,
    end: _end,
    mute: _mute,
    speed: _speed,
    turns: _turns,
    edits: _e.copy(),
    preset: _preset,
    overlays: List.of(_overlays),
    music: _music,
    audio: _a,
  );

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _noteChange();
  }

  /// Something may have changed: a new undo step, unless it is part of the change just
  /// before (sliders and handles send many small changes).
  void _noteChange() {
    if (_restoring) return;
    final next = _snap();
    final cur = _now;
    if (cur == null) {
      _now = next;
      return;
    }
    if (cur.sig == next.sig) return;
    final t = DateTime.now();
    if (t.difference(_lastChange).inMilliseconds > 700) {
      _undo.add(cur);
      if (_undo.length > 60) _undo.removeAt(0);
    }
    _lastChange = t;
    _now = next;
    if (_redo.isNotEmpty) _redo.clear();
  }

  bool get _canUndo => _undo.isNotEmpty && !_recording && !_busy;
  bool get _canRedo => _redo.isNotEmpty && !_recording && !_busy;

  Future<void> _undoStep() async {
    if (!_canUndo) return;
    _redo.add(_now ?? _snap());
    await _restore(_undo.removeLast());
  }

  Future<void> _redoStep() async {
    if (!_canRedo) return;
    _undo.add(_now ?? _snap());
    await _restore(_redo.removeLast());
  }

  Future<void> _restore(_Snap x) async {
    final musicChanged = x.music?.id != _music?.id;
    final voiceChanged = x.audio.voicePath != _a.voicePath;
    final speedChanged = x.speed != _speed;
    final songStartChanged = x.audio.songStart != _a.songStart;
    _restoring = true;
    setState(() {
      _start = x.start;
      _end = x.end;
      _mute = x.mute;
      _speed = x.speed;
      _turns = x.turns;
      _e = x.edits.copy();
      _preset = x.preset;
      _overlays
        ..clear()
        ..addAll(x.overlays);
      _sel = null;
      _music = x.music;
      _a = x.audio;
      _rangeN.value = (_start, _end);
    });
    _ovTick.value++;
    _now = x;
    _lastChange = DateTime.fromMillisecondsSinceEpoch(0);
    _restoring = false;
    if (musicChanged || songStartChanged) {
      final m = _music;
      if (m == null) {
        final old = _player;
        _player = null;
        await old?.dispose();
      } else {
        await _startPlayer(m);
      }
    } else {
      _player?.setVolume(_a.songVolume);
    }
    if (voiceChanged) {
      await _startVoice();
    } else {
      _voice?.setVolume(_a.voiceVolume);
    }
    final c = _c;
    if (c != null) {
      if (speedChanged) {
        _smooth.rate = _speed;
        await c.setPlaybackSpeed(_speed);
      }
      await c.setVolume(_videoVolume);
      final p = _pos.value;
      if (p < _start || p > _end) _scrubTo(_start);
      _syncSound(force: true);
    }
  }

  // ------------------------------------------------------------- captions

  /// A caption: a short line with a background, low on the picture, on screen for three
  /// seconds from where the playhead is (drag its ends on the timeline to change that).
  Future<void> _addCaption() async {
    final at = _pos.value.clamp(_start, _end);
    final r = await showOverlayTextSheet(
      context,
      const StoryOverlay(text: '', pill: true),
    );
    if (r == null || r.text.trim().isEmpty || !mounted) return;
    final to = math.min(at + 3, _end);
    setState(() {
      _overlays.add(
        r.copyWith(
          dx: 0.5,
          dy: 0.84,
          pill: true,
          scale: 0.85,
          from: at,
          to: to >= _total - 0.01 ? -1 : to,
        ),
      );
      _sel = _overlays.length - 1;
    });
    _ovTick.value++;
  }

  static bool _isCaption(StoryOverlay o) =>
      o.pill && o.dy > 0.75 && !o.emoji && !o.isImage;

  // --------------------------------------------------------------- scrub

  void _scrubStart() {
    final c = _c;
    if (c == null || _recording) return;
    _playBeforeScrub = !_paused;
    if (!_paused) {
      _paused = true;
      c.pause();
      _player?.pause();
      _voice?.pause();
    }
  }

  void _scrubMove(double sec) {
    if (_recording) return;
    _scrubTo(sec.clamp(_start, math.max(_start, _end - 0.05)));
  }

  void _scrubEnd() {
    if (_recording) return;
    if (_playBeforeScrub) {
      setState(() => _paused = true);
      _togglePause();
    } else {
      setState(() {});
    }
  }

  // ------------------------------------------------------------------- done

  Future<void> _done() async {
    if (_busy) return;
    if (_isVideo) {
      if (_recording) await _stopRecording();
      if (!mounted) return;
      _keptVoice = _a.voicePath;
      final ve = VideoEdits(
        start: _start.round(),
        end: _end.round(),
        total: _total,
        mute: _mute,
        speed: _speed,
        turns: _turns,
      );
      final look = VideoLook(
        filter: _e.filter,
        brightness: _e.brightness,
        contrast: _e.contrast,
        saturation: _e.saturation,
      );
      Navigator.of(context).pop(
        EditorResult(
          videoEdits: ve.isEmpty ? null : ve,
          look: look.isEmpty ? null : look,
          overlays: List.of(_overlays),
          music: _music,
          audio: _a,
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final f = await finishPhoto(widget.file, _e, _overlays);
      if (!mounted) return;
      Navigator.of(context).pop(
        EditorResult(
          photoFile: f,
          photoEdits: _e.isEmpty ? null : _e,
          overlays: List.of(_overlays),
          music: _music,
          audio: _a,
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        showToast(context, 'Could not save the edits. Try again.');
      }
    }
  }

  // ------------------------------------------------------------------ layout

  @override
  Widget build(BuildContext context) {
    final ready = _isVideo ? _c != null : _proxy != null;
    return Theme(
      data: AppTheme.dark,
      child: Builder(
        builder: (context) => PopScope(
          canPop: !_busy,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  _topBar(context, ready),
                  Expanded(child: _body(context)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Round close button, the title in a pill, and a white round arrow to finish.
  Widget _topBar(BuildContext context, bool ready) {
    Widget round({
      required Key key,
      required Widget child,
      required VoidCallback? onTap,
      Color color = const Color(0xFF1F1F23),
      String? tip,
    }) => Tooltip(
      message: tip ?? '',
      child: Material(
        key: key,
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 52, height: 52, child: Center(child: child)),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Row(
        children: [
          round(
            key: const ValueKey('editorClose'),
            tip: 'Close',
            onTap: _busy ? null : () => Navigator.of(context).pop(),
            child: const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: Colors.white,
              size: 32,
            ),
          ),
          Expanded(
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF1F1F23),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  _isVideo ? 'Edit clip' : 'Edit photo',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
          round(
            key: const ValueKey('editorDone'),
            tip: 'Done',
            color: Colors.white,
            onTap: _busy || !ready ? null : _done,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.black,
                    ),
                  )
                : const Icon(
                    Icons.arrow_forward_rounded,
                    color: Colors.black,
                    size: 28,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loadError != null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'This file cannot be edited. You can still post it as it is.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_isVideo ? _c == null : _proxy == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final toolOpen = _tool != null;
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              _isVideo ? 56 : 16,
              4,
              _isVideo ? 56 : 16,
              6,
            ),
            child: LayoutBuilder(builder: _preview),
          ),
        ),
        _controls(),
        if (_isVideo) ...[
          const Divider(height: 1, color: Colors.white12),
          _timeline(compact: toolOpen),
        ],
        _selectionBar(),
        if (toolOpen)
          SizedBox(
            height: _tool == _Tool.audio ? 176 : (_isVideo ? 120 : 150),
            child: switch (_tool!) {
              _Tool.crop => _cropTools(),
              _Tool.filters => _filterTools(),
              _Tool.adjust => _adjustTools(),
              _Tool.audio => _audioTools(),
              _Tool.speed => _speedTools(),
            },
          )
        else if (_isVideo && _sel == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'Tap on a track to trim. Pinch to zoom.',
              key: ValueKey('timelineHint'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 14.5),
            ),
          ),
        _panel(context),
      ],
    );
  }

  /// Play / pause, the time, undo and redo.
  Widget _controls() {
    Widget circle(
      Key key,
      IconData icon,
      VoidCallback? onTap, {
      double size = 26,
    }) => Material(
      key: key,
      color: const Color(0xFF1F1F23),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            icon,
            size: size,
            color: onTap == null ? Colors.white30 : Colors.white,
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
      child: Row(
        children: [
          if (_isVideo)
            circle(
              const ValueKey('editorPlay'),
              _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
              _recording ? null : _togglePause,
              size: 30,
            )
          else
            const SizedBox(width: 48),
          Expanded(
            child: _isVideo
                ? ValueListenableBuilder<double>(
                    valueListenable: _pos,
                    builder: (_, p, _) {
                      final sp = _speed <= 0 ? 1.0 : _speed;
                      final at = ((p - _start) / sp).clamp(0.0, 36000.0);
                      final len = (_end - _start) / sp;
                      return Text(
                        '${_clock2(at)} / ${_clock2(len)}',
                        key: const ValueKey('editorTime'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 17,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      );
                    },
                  )
                : const SizedBox.shrink(),
          ),
          circle(
            const ValueKey('editorUndo'),
            Icons.undo_rounded,
            _canUndo ? _undoStep : null,
          ),
          const SizedBox(width: 10),
          circle(
            const ValueKey('editorRedo'),
            Icons.redo_rounded,
            _canRedo ? _redoStep : null,
          ),
        ],
      ),
    );
  }

  // ---- photo preview ----

  double get _photoAspect {
    final p = _proxy!;
    final odd = _e.turns % 2 == 1;
    return odd ? p.height / p.width : p.width / p.height;
  }

  double? get _lock {
    final v = _presets[_preset].$2;
    if (v == null) return null;
    return v < 0 ? _photoAspect : v;
  }

  Widget _imageWidget() {
    final p = _proxy!;
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(_e.colorMatrix),
      child: Transform.flip(
        flipX: _e.flip,
        child: RotatedBox(
          quarterTurns: _e.turns,
          child: Image.file(
            p.file,
            fit: BoxFit.fill,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
    );
  }

  Widget _overlayLayer() => ValueListenableBuilder<int>(
    valueListenable: _ovTick,
    builder: (_, _, _) => OverlayEditLayer(
      overlays: _overlays,
      onChanged: (l) => setState(() {
        _overlays
          ..clear()
          ..addAll(l);
      }),
      onTap: _tapOverlay,
      selected: _sel,
      onBackgroundTap: () => setState(() => _sel = null),
      position: _isVideo ? _pos : null,
    ),
  );

  Widget _preview(BuildContext context, BoxConstraints c) {
    if (_isVideo) return _videoPreview(c);
    final cropping = _tool == _Tool.crop;
    final full = _photoAspect;
    final crop = _e.crop;
    final shown = cropping ? full : full * crop.width / crop.height;
    var w = c.maxWidth;
    var h = w / shown;
    if (h > c.maxHeight) {
      h = c.maxHeight;
      w = h * shown;
    }
    Widget content;
    if (cropping) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          _imageWidget(),
          CropOverlay(
            rect: crop,
            lock: _lock,
            photoAspect: full,
            onChanged: (r) => setState(() => _e.crop = r),
          ),
        ],
      );
    } else {
      final fullW = w / crop.width;
      final fullH = h / crop.height;
      final ax = crop.width >= 0.999
          ? 0.0
          : 2 * crop.left / (1 - crop.width) - 1;
      final ay = crop.height >= 0.999
          ? 0.0
          : 2 * crop.top / (1 - crop.height) - 1;
      content = Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(
            child: Align(
              alignment: Alignment(ax, ay),
              widthFactor: crop.width,
              heightFactor: crop.height,
              child: SizedBox(
                width: fullW,
                height: fullH,
                child: _imageWidget(),
              ),
            ),
          ),
          _overlayLayer(),
        ],
      );
    }
    return Center(
      child: SizedBox(width: w, height: h, child: content),
    );
  }

  // ---- video preview ----

  Widget _videoPreview(BoxConstraints c) {
    final v = _c!;
    final size = v.value.size;
    final raw = size.height == 0 ? 16 / 9 : size.width / size.height;
    final aspect = _turns.isOdd ? 1 / raw : raw;
    var w = c.maxWidth;
    var h = w / aspect;
    if (h > c.maxHeight) {
      h = c.maxHeight;
      w = h * aspect;
    }
    final look = VideoLook(
      filter: _e.filter,
      brightness: _e.brightness,
      contrast: _e.contrast,
      saturation: _e.saturation,
    );
    Widget video = VideoPlayer(v);
    if (!look.isEmpty) {
      video = ColorFiltered(colorFilter: lookFilter(look), child: video);
    }
    if (_turns != 0) video = RotatedBox(quarterTurns: _turns, child: video);
    return Center(
      child: Container(
        width: w,
        height: h,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              key: const ValueKey('editorVideo'),
              behavior: HitTestBehavior.opaque,
              onTap: _togglePause,
              child: video,
            ),
            _overlayLayer(),
            if (_recording)
              Positioned(
                top: 10,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    key: const ValueKey('voiceRecording'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.redAccent,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.mic_rounded, size: 18, color: Colors.white),
                        SizedBox(width: 6),
                        Text(
                          'Recording - tap Voice to stop',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_paused)
              const IgnorePointer(
                child: Center(
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 72,
                    shadows: [Shadow(blurRadius: 14, color: Colors.black54)],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---- bottom: tool panel and tool row ----

  Widget _panel(BuildContext context) {
    final voice = _isVideo && widget.voiceover;
    return SafeArea(
      top: false,
      child: SizedBox(
        height: 104,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          children: [
            _actionButton(
              const ValueKey('tool_audio'),
              Icons.library_music_rounded,
              _music == null ? 'Audio' : _music!.title,
              _audio,
              on: _music != null,
            ),
            if (_music != null || (voice && _a.hasVoice))
              _toolButton(
                const ValueKey('tool_audio_edit'),
                Icons.graphic_eq_rounded,
                'Edit audio',
                _Tool.audio,
              ),
            if (_music != null)
              _actionButton(
                const ValueKey('tool_audio_off'),
                Icons.music_off_rounded,
                'No audio',
                _removeAudio,
              ),
            _actionButton(
              const ValueKey('tool_text'),
              Icons.text_fields_rounded,
              'Text',
              _addText,
            ),
            if (voice)
              _actionButton(
                const ValueKey('tool_voice'),
                _recording ? Icons.stop_circle_rounded : Icons.mic_none_rounded,
                _recording ? 'Stop' : 'Voice',
                _recordVoice,
                on: _recording || _a.hasVoice,
                badge: _a.hasVoice || _recording ? null : 'New',
              ),
            if (_isVideo)
              _actionButton(
                const ValueKey('tool_captions'),
                Icons.closed_caption_outlined,
                'Captions',
                _addCaption,
                badge: 'New',
              ),
            _actionButton(
              const ValueKey('tool_stickers'),
              Icons.sticky_note_2_outlined,
              'Stickers',
              _addSticker,
            ),
            _toolButton(
              const ValueKey('tool_filters'),
              Icons.filter_vintage_outlined,
              'Filters',
              _Tool.filters,
            ),
            _toolButton(
              const ValueKey('tool_adjust'),
              Icons.tune_rounded,
              'Adjust',
              _Tool.adjust,
            ),
            if (!_isVideo)
              _toolButton(
                const ValueKey('tool_crop'),
                Icons.crop_rounded,
                'Crop',
                _Tool.crop,
              ),
            if (_isVideo) ...[
              _toolButton(
                const ValueKey('tool_speed'),
                Icons.speed_rounded,
                _speed == 1 ? 'Speed' : speedLabel(_speed),
                _Tool.speed,
              ),
              _actionButton(
                const ValueKey('tool_rotate'),
                Icons.rotate_90_degrees_cw_rounded,
                _turns == 0 ? 'Rotate' : '${_turns * 90}\u00b0',
                _turnVideo,
                on: _turns != 0,
              ),
              _actionButton(
                const ValueKey('tool_mute'),
                _mute ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                _mute ? 'Muted' : 'Volume',
                _toggleMute,
                on: _mute,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _toolButton(
    Key key,
    IconData icon,
    String label,
    _Tool t,
  ) => _actionButton(
    key,
    icon,
    label,
    // on a video a second tap closes the tool again, so the timeline keeps its room;
    // on a photo the audio tool goes back to the filters
    () => setState(() {
      if (_tool != t) {
        _tool = t;
      } else if (_isVideo) {
        _tool = null;
      } else if (t == _Tool.audio) {
        _tool = _Tool.filters;
      }
    }),
    on: _tool == t,
  );

  /// A rounded square with the icon and the name under it (and a little "New" tag).
  Widget _actionButton(
    Key key,
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool on = false,
    String? badge,
  }) {
    final locked = _recording && key != const ValueKey('tool_voice');
    final fg = on ? AppTheme.volt : Colors.white;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(16),
        onTap: _busy || locked ? null : onTap,
        child: SizedBox(
          width: 82,
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.topCenter,
                children: [
                  Container(
                    width: 74,
                    height: 56,
                    decoration: BoxDecoration(
                      color: on
                          ? AppTheme.volt.withValues(alpha: 0.16)
                          : const Color(0xFF1F1F23),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      icon,
                      size: 28,
                      color: locked ? Colors.white30 : fg,
                    ),
                  ),
                  if (badge != null)
                    Positioned(
                      top: -9,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF5B6CFF),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          badge,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: on ? AppTheme.volt : Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _laneLabel(StoryOverlay o) {
    if (o.isImage) return 'GIF';
    final t = o.text.trim();
    return t.isEmpty ? (o.emoji ? 'Sticker' : 'Text') : t;
  }

  /// Always in view for a video, like video editors: the playhead in the middle, the clip
  /// with its frames, the song, the voiceover and every text, sticker and caption.
  Widget _timeline({bool compact = false}) {
    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: Listenable.merge([_rangeN, _ovTick, _framesTick]),
        builder: (context, _) {
          final r = _rangeN.value;
          return EditTimeline(
            height: compact ? 150 : 214,
            total: _total,
            start: r.$1,
            end: r.$2,
            position: _pos,
            frames: _frames,
            maxSeconds: widget.maxSeconds,
            muted: _mute,
            videoSelected: _videoSel,
            audioLabel: _music?.title,
            voice: widget.voiceover && _a.hasVoice,
            lanes: [
              for (var i = 0; i < _overlays.length; i++)
                EditLane(
                  icon: _isCaption(_overlays[i])
                      ? Icons.closed_caption_rounded
                      : (_overlays[i].emoji || _overlays[i].isImage
                            ? Icons.emoji_emotions_rounded
                            : Icons.text_fields_rounded),
                  label: _laneLabel(_overlays[i]),
                  from: _overlays[i].from,
                  to: _overlays[i].to,
                  selected: _sel == i,
                ),
            ],
            onSeekStart: _scrubStart,
            onSeek: _scrubMove,
            onSeekEnd: _scrubEnd,
            onRange: (s, e, startMoved) => _applyRange(s, e, startMoved),
            onVideoTap: () => setState(() {
              _videoSel = !_videoSel;
              _sel = null;
            }),
            onMuteTap: _recording ? null : _toggleMute,
            onAddAudio: _recording ? null : _audio,
            onAudioTap: () => setState(() {
              _videoSel = false;
              _tool = _tool == _Tool.audio ? null : _Tool.audio;
            }),
            onVoiceTap: () => setState(() {
              _videoSel = false;
              _tool = _tool == _Tool.audio ? null : _Tool.audio;
            }),
            onLaneTap: (i) => setState(() {
              _videoSel = false;
              _sel = _sel == i ? null : i;
            }),
            onLaneRange: (i, from, to) {
              if (i >= _overlays.length) return;
              _overlays[i] = _overlays[i].copyWith(from: from, to: to);
              _ovTick.value++;
              _noteChange();
            },
            onAddText: _recording ? null : _addText,
          );
        },
      ),
    );
  }

  static String _clock2(double s) {
    final v = s.round();
    return '${v ~/ 60}:${(v % 60).toString().padLeft(2, '0')}';
  }

  /// One labelled slider of the audio tool.
  Widget _slider(
    Key key,
    String label,
    double value,
    double max,
    String shown,
    ValueChanged<double> onChanged, {
    ValueChanged<double>? onEnd,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 112,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
          ),
        ),
        Expanded(
          child: Slider(
            key: key,
            value: value.clamp(0.0, max),
            max: max,
            onChanged: onChanged,
            onChangeEnd: onEnd,
          ),
        ),
        SizedBox(
          width: 46,
          child: Text(
            shown,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ),
      ],
    );
  }

  /// Which part of the song, the volumes, the fades and the voiceover.
  Widget _audioTools() {
    final p = _player;
    final songLen = p != null && p.ready
        ? p.duration.inMilliseconds / 1000
        : (_music?.seconds ?? 0).toDouble();
    final startMax = songLen > 2 ? songLen - 1 : 0.0;
    String pct(double v) => '${(v * 100).round()}%';
    return ListView(
      key: const ValueKey('audioTools'),
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
      children: [
        if (_music != null) ...[
          if (startMax > 0)
            _slider(
              const ValueKey('songStart'),
              'Song starts at',
              _a.songStart,
              startMax,
              _clock2(_a.songStart),
              _setSongStart,
              onEnd: (_) => _songStartDone(),
            ),
          _slider(
            const ValueKey('songVolume'),
            'Song volume',
            _a.songVolume,
            1,
            pct(_a.songVolume),
            _setSongVolume,
          ),
        ],
        if (_isVideo) ...[
          _slider(
            const ValueKey('originalVolume'),
            'Original sound',
            _speed != 1 || _mute ? 0 : _a.originalVolume,
            1,
            _speed != 1 ? 'off' : (_mute ? 'muted' : pct(_a.originalVolume)),
            _speed != 1 || _mute ? (_) {} : _setOriginalVolume,
          ),
          if (_music != null) ...[
            _slider(
              const ValueKey('fadeIn'),
              'Fade in',
              _a.fadeIn,
              AudioEdits.maxFade,
              '${_a.fadeIn.toStringAsFixed(1)} s',
              (v) => setState(() => _a = _a.copyWith(fadeIn: v)),
            ),
            _slider(
              const ValueKey('fadeOut'),
              'Fade out',
              _a.fadeOut,
              AudioEdits.maxFade,
              '${_a.fadeOut.toStringAsFixed(1)} s',
              (v) => setState(() => _a = _a.copyWith(fadeOut: v)),
            ),
          ],
          if (_a.hasVoice)
            Row(
              children: [
                Expanded(
                  child: _slider(
                    const ValueKey('voiceVolume'),
                    'Voiceover',
                    _a.voiceVolume,
                    1,
                    pct(_a.voiceVolume),
                    _setVoiceVolume,
                  ),
                ),
                IconButton(
                  key: const ValueKey('voiceDelete'),
                  tooltip: 'Delete the voiceover',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: _deleteVoice,
                ),
              ],
            ),
          if (_speed != 1)
            const Padding(
              padding: EdgeInsets.only(top: 2, bottom: 6),
              child: Text(
                'At another speed the original sound is left out; songs and voiceovers keep their own speed.',
                style: TextStyle(fontSize: 11.5, color: Colors.white54),
              ),
            ),
        ],
      ],
    );
  }

  /// 0.5x to 2x (the picture only).
  Widget _speedTools() {
    return Center(
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          for (final sp in kClipSpeeds)
            ChoiceChip(
              key: ValueKey('speed_$sp'),
              label: Text(speedLabel(sp)),
              selected: _speed == sp,
              onSelected: (_) => _setSpeed(sp),
            ),
        ],
      ),
    );
  }

  Widget _cropTools() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: 'Rotate left',
              icon: const Icon(Icons.rotate_left_rounded),
              onPressed: () => _rotate(-1),
            ),
            IconButton(
              tooltip: 'Rotate right',
              icon: const Icon(Icons.rotate_right_rounded),
              onPressed: () => _rotate(1),
            ),
            IconButton(
              tooltip: 'Flip',
              icon: const Icon(Icons.flip_rounded),
              onPressed: _flip,
            ),
          ],
        ),
        SizedBox(
          height: 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _presets.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) => Center(
              child: ChoiceChip(
                label: Text(_presets[i].$1),
                selected: _preset == i,
                showCheckmark: false,
                selectedColor: AppTheme.volt,
                labelStyle: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: _preset == i ? AppTheme.ink : Colors.white,
                ),
                onSelected: (_) => _pickPreset(i),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _filterTools() {
    final thumb = _thumb;
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      itemCount: kPhotoFilters.length,
      separatorBuilder: (_, _) => const SizedBox(width: 10),
      itemBuilder: (context, i) {
        final on = _e.filter == i;
        return GestureDetector(
          onTap: () => setState(() => _e.filter = i),
          child: Column(
            children: [
              Container(
                width: 68,
                height: 76,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: on ? AppTheme.volt : Colors.transparent,
                    width: 2.5,
                  ),
                ),
                child: ColorFiltered(
                  colorFilter: ColorFilter.matrix(kPhotoFilters[i].matrix),
                  child: thumb == null
                      ? const ColoredBox(color: Colors.white24)
                      : Image.file(thumb, fit: BoxFit.cover, cacheWidth: 160),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                kPhotoFilters[i].name,
                style: TextStyle(
                  color: on ? AppTheme.volt : Colors.white70,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _adjustTools() {
    Widget slider(
      String label,
      double value,
      double min,
      double max,
      double neutral,
      ValueChanged<double> onChanged,
    ) {
      return Row(
        children: [
          SizedBox(
            width: 92,
            child: Padding(
              padding: const EdgeInsets.only(left: 18),
              child: Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13.5,
                ),
              ),
            ),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              activeColor: AppTheme.volt,
              onChanged: (v) {
                // a little "snap" at the neutral value
                onChanged(
                  (v - neutral).abs() < (max - min) * 0.025 ? neutral : v,
                );
              },
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '${((value - neutral) / (max - min) * 200).round()}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12.5),
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        slider(
          'Brightness',
          _e.brightness,
          -1,
          1,
          0,
          (v) => setState(() => _e.brightness = v),
        ),
        slider(
          'Contrast',
          _e.contrast,
          0.5,
          1.5,
          1,
          (v) => setState(() => _e.contrast = v),
        ),
        slider(
          'Colour',
          _e.saturation,
          0,
          2,
          1,
          (v) => setState(() => _e.saturation = v),
        ),
      ],
    );
  }
}

/// Everything undo and redo bring back.
class _Snap {
  _Snap({
    required this.start,
    required this.end,
    required this.mute,
    required this.speed,
    required this.turns,
    required this.edits,
    required this.preset,
    required this.overlays,
    required this.music,
    required this.audio,
  });

  final double start;
  final double end;
  final bool mute;
  final double speed;
  final int turns;
  final PhotoEdits edits;
  final int preset;
  final List<StoryOverlay> overlays;
  final MusicTrack? music;
  final AudioEdits audio;

  /// Two snapshots with the same fingerprint are the same edit.
  late final String sig = [
    start,
    end,
    mute,
    speed,
    turns,
    preset,
    edits.turns,
    edits.flip,
    edits.crop,
    edits.filter,
    edits.brightness,
    edits.contrast,
    edits.saturation,
    music?.id,
    audio.hashCode,
    for (final o in overlays)
      '${o.text}|${o.dx}|${o.dy}|${o.scale}|${o.color}|${o.pill}|${o.emoji}|${o.image}|${o.from}|${o.to}',
  ].join('~');
}
