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
import '../../services/video_frames.dart';
import '../../widgets/music_widgets.dart';
import '../../widgets/overlay_tools.dart';
import '../../widgets/edit_timeline.dart';
import '../../widgets/media_layers.dart';
import 'package:image_picker/image_picker.dart';
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
    this.layers = const [],
    this.mask,
  });

  /// Videos: photos / videos placed over the clip (Overlay) and the clip's mask.
  final List<MediaLayer> layers;
  final LayerMask? mask;

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
    this.layers = const [],
    this.mask,
  });

  /// Videos: layers placed over the clip and the clip's mask.
  final List<MediaLayer> layers;
  final LayerMask? mask;

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

/// Test hook: picks a photo or video for Overlay (file, width / height).
Future<(File, double)?> Function(bool video)? debugPickLayer;

enum _Tool { filters, adjust, crop, audio, speed, split, layer, mask }

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
  bool _paused = false; // videos open paused (set in initState)

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

  // split: cut points (whole seconds) and the parts taken out (by their first second)
  final List<int> _cuts = [];
  final Set<int> _removed = {};

  // layers placed over the clip, the clip's own mask
  final List<MediaLayer> _layers = [];
  LayerMask? _clipMask;
  int? _layerSel;
  int _layerTab = 0;
  final ValueNotifier<bool> _playingN = ValueNotifier(false);
  double _layerBaseScale = 1;
  double _layerBaseTurns = 0;
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
    _layers.addAll(widget.layers);
    _clipMask = widget.mask;
    _music = widget.music;
    if (_isVideo) {
      _tool = null;
      _paused = true; // nothing plays until play is tapped
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
        _restoreParts(init?.parts ?? const []);
        _rangeN.value = (_start, _end);
      });
      _smooth.rate = _speed;
      await c.setLooping(false);
      await c.setVolume(_videoVolume);
      if (_speed != 1) await c.setPlaybackSpeed(_speed);
      c.addListener(_tick);
      unawaited(_loadFrames());
      await c.seekTo(Duration(milliseconds: (_playStart * 1000).round()));
      _smooth.seek(_playStart, _clock.elapsed);
      _pos.value = _playStart;
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
          position: framePosition(((i + 0.5) / n * _total * 1000).round()),
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
    _playingN.value = v.isPlaying;
    if (v.isPlaying && !_tk.isActive) {
      _tk.start();
    } else if (!v.isPlaying && _tk.isActive) {
      _tk.stop();
      _pos.value = _smooth.value(now);
    }
    if (_paused) return;
    final end = Duration(milliseconds: (_playEnd * 1000).round());
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
    if (est >= _playEnd - 0.02) {
      _loopBack();
      return;
    }
    final skip = _recording ? null : _skipFrom(est);
    if (skip != null) {
      skip.isInfinite ? _loopBack() : _jumpTo(skip);
      return;
    }
    _pos.value = est;
  }

  /// Playing ran into a part that was taken out: on to the next kept part.
  void _jumpTo(double sec) {
    final c = _c;
    if (c == null || _looping) return;
    _looping = true;
    _smooth.seek(sec, _clock.elapsed);
    _pos.value = sec;
    c.seekTo(Duration(milliseconds: (sec * 1000).round())).whenComplete(() {
      _looping = false;
      _syncSound(force: true, at: sec);
    });
  }

  // ------------------------------------------------------------------ split

  /// The parts between the trim handles and the cuts (seconds of the video).
  List<(double, double)> get _segs {
    final b = <double>[
      _start,
      for (final x in _cuts)
        if (x > _start + 0.01 && x < _end - 0.01) x.toDouble(),
      _end,
    ];
    return [for (var i = 0; i + 1 < b.length; i++) (b[i], b[i + 1])];
  }

  bool _isRemoved((double, double) seg) => _removed.contains(seg.$1.round());

  /// The parts that are kept (never none).
  List<(double, double)> get _keptSegs {
    final all = _segs;
    final k = [
      for (final g in all)
        if (!_isRemoved(g)) g,
    ];
    return k.isEmpty ? all : k;
  }

  double get _playStart => _keptSegs.first.$1;
  double get _playEnd => _keptSegs.last.$2;

  /// Seconds of the finished clip (before the speed) that come before [sec] of the video.
  double _outOffset(double sec) {
    var acc = 0.0;
    for (final g in _keptSegs) {
      if (sec <= g.$1) break;
      acc += math.min(sec, g.$2) - g.$1;
    }
    return acc;
  }

  double get _keptLength => _keptSegs.fold(0.0, (a, g) => a + g.$2 - g.$1);

  /// [sec] is inside a part that was taken out: where playing goes on (infinity = loop).
  double? _skipFrom(double sec) {
    if (_removed.isEmpty) return null;
    for (final g in _segs) {
      if (sec >= g.$1 - 0.001 && sec < g.$2 - 0.01) {
        if (!_isRemoved(g)) return null;
        for (final k in _keptSegs) {
          if (k.$1 >= g.$2 - 0.001) return k.$1;
        }
        return double.infinity;
      }
    }
    return null;
  }

  /// Kept parts in whole seconds, neighbours joined.
  List<(int, int)> get _keptParts {
    final out = <(int, int)>[];
    for (final g in _keptSegs) {
      final a = g.$1.round(), b = g.$2.round();
      if (b <= a) continue;
      if (out.isNotEmpty && out.last.$2 == a) {
        out[out.length - 1] = (out.last.$1, b);
      } else {
        out.add((a, b));
      }
    }
    return out;
  }

  /// Opening the editor again: cuts and taken-out parts from the saved parts.
  void _restoreParts(List<(int, int)> parts) {
    if (parts.length < 2) return;
    _start = parts.first.$1.toDouble();
    _end = parts.last.$2.toDouble();
    for (var i = 0; i + 1 < parts.length; i++) {
      final a = parts[i].$2, b = parts[i + 1].$1;
      _cuts.add(a);
      if (b > a) {
        _cuts.add(b);
        _removed.add(a);
      }
    }
    _cuts.sort();
  }

  /// Split at the playhead (whole seconds; a part is at least one second).
  void _splitHere() {
    final at = _pos.value.round();
    final ok = at > _start.round() && at < _end.round() && !_cuts.contains(at);
    if (!ok) {
      showToast(context, 'Move the playhead inside the clip to split.');
      return;
    }
    setState(() {
      final seg = _segs.firstWhere((g) => at > g.$1 && at < g.$2);
      _cuts
        ..add(at)
        ..sort();
      if (_isRemoved(seg)) _removed.add(at);
    });
  }

  void _toggleSeg((double, double) g) {
    final key = g.$1.round();
    if (!_removed.contains(key) && _keptSegs.length <= 1) {
      showToast(context, 'At least one part has to stay.');
      return;
    }
    setState(() {
      if (!_removed.remove(key)) _removed.add(key);
    });
    final p = _pos.value;
    final skip = _skipFrom(p);
    if (skip != null) _scrubTo(skip.isInfinite ? _playStart : skip);
  }

  void _joinAll() => setState(() {
    _cuts.clear();
    _removed.clear();
  });

  void _loopBack() {
    final c = _c;
    if (c == null || _looping) return;
    if (_recording) {
      // the voiceover covers the clip once: at its end the recording stops
      unawaited(_stopRecording());
      return;
    }
    _looping = true;
    final from = _playStart;
    _smooth.seek(from, _clock.elapsed);
    _pos.value = from;
    c
        .seekTo(Duration(milliseconds: (from * 1000).round()))
        .then((_) => c.play())
        .whenComplete(() {
          _looping = false;
          _syncSound(force: true, at: from);
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
    // where the finished clip is: parts that were taken out do not count
    final videoSec =
        _playStart + _outOffset(at ?? c.value.position.inMilliseconds / 1000);
    final p = _player;
    if (p != null && p.ready) {
      final len = p.duration.inMilliseconds / 1000;
      final want = songPositionFor(
        videoSec: videoSec,
        trimStart: _playStart,
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
        trimStart: _playStart,
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
    _playingN.dispose();
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
    await c.seekTo(Duration(milliseconds: (_playStart * 1000).round()));
    _smooth.seek(_playStart, _clock.elapsed);
    _pos.value = _playStart;
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
      await c.seekTo(Duration(milliseconds: (_playStart * 1000).round()));
      _smooth.seek(_playStart, _clock.elapsed);
      _pos.value = _playStart;
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
      _syncSound(force: true, at: _playStart);
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
      onAnimate: _isVideo ? () => _animateOverlay(i) : null,
    );
  }

  Future<void> _animateOverlay(int i) async {
    final a = await showMotionSheet(context, _overlays[i].anim);
    if (a == null || !mounted || i >= _overlays.length) return;
    setState(() {
      _overlays[i] = a.isEmpty
          ? _overlays[i].copyWith(clearAnim: true)
          : _overlays[i].copyWith(anim: a);
    });
    _ovTick.value++;
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
      final p = _pos.value;
      final skip = _skipFrom(p);
      if (p < _playStart || p >= _playEnd - 0.05 || skip != null) {
        _scrubTo(skip == null || skip.isInfinite ? _playStart : skip);
      }
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
    // the picture shows the handle being moved; the tracks (and playhead) stay still so
    // the handle stays under the finger
    final at = startMoved ? _start : math.max(_start, _end - 0.1);
    _seek.request(Duration(milliseconds: (at * 1000).round()));
  }

  /// A trim handle was grabbed: the video pauses.
  void _trimStart() => _timelineTouched();

  /// A trim handle was let go: the playhead goes to the start of the kept part.
  void _trimEnd() {
    final p = _pos.value;
    _scrubTo(p < _start || p > _end - 0.05 ? _start : p);
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
    cuts: List.of(_cuts),
    removed: Set.of(_removed),
    layers: List.of(_layers),
    mask: _clipMask,
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
      _cuts
        ..clear()
        ..addAll(x.cuts);
      _removed
        ..clear()
        ..addAll(x.removed);
      _layers
        ..clear()
        ..addAll(x.layers);
      _clipMask = x.mask;
      if (_layerSel != null && _layerSel! >= _layers.length) _layerSel = null;
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
      if (p < _start || p > _end) _scrubTo(_playStart);
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
    if (!_paused) {
      setState(() => _paused = true);
      c.pause();
      _player?.pause();
      _voice?.pause();
    }
  }

  void _scrubMove(double sec) {
    if (_recording) return;
    _scrubTo(sec.clamp(_start, math.max(_start, _end - 0.05)));
  }

  /// The video stays paused after touching the timeline (play continues it).
  void _scrubEnd() {
    if (_recording) return;
    setState(() {});
  }

  /// Any touch on the timeline pauses the video.
  void _timelineTouched() {
    final c = _c;
    if (c == null || _recording || _paused) return;
    setState(() => _paused = true);
    c.pause();
    _player?.pause();
    _voice?.pause();
  }

  // ------------------------------------------------------------------- done

  Future<void> _done() async {
    if (_busy) return;
    if (_isVideo) {
      if (_recording) await _stopRecording();
      if (!mounted) return;
      _keptVoice = _a.voicePath;
      final parts = _keptParts;
      final ve = VideoEdits(
        start: parts.isEmpty ? _start.round() : parts.first.$1,
        end: parts.isEmpty ? _end.round() : parts.last.$2,
        total: _total,
        mute: _mute,
        speed: _speed,
        turns: _turns,
        parts: parts.length > 1 ? parts : const [],
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
          layers: List.of(_layers),
          mask: _clipMask,
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
          child: SizedBox(width: 40, height: 40, child: Center(child: child)),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: [
          round(
            key: const ValueKey('editorClose'),
            tip: 'Close',
            onTap: _busy ? null : () => Navigator.of(context).pop(),
            child: const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: Colors.white,
              size: 26,
            ),
          ),
          Expanded(
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF1F1F23),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _isVideo ? 'Edit clip' : 'Edit photo',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
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
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.black,
                    ),
                  )
                : const Icon(
                    Icons.arrow_forward_rounded,
                    color: Colors.black,
                    size: 22,
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
            height: switch (_tool!) {
              _Tool.audio => 176,
              _Tool.layer => 172,
              _Tool.mask => 132,
              _Tool.split => 140,
              _ => _isVideo ? 120 : 150,
            },
            child: switch (_tool!) {
              _Tool.crop => _cropTools(),
              _Tool.filters => _filterTools(),
              _Tool.adjust => _adjustTools(),
              _Tool.audio => _audioTools(),
              _Tool.speed => _speedTools(),
              _Tool.split => _splitTools(),
              _Tool.layer => _layerTools(),
              _Tool.mask => _maskTools(),
            },
          )
        else if (_isVideo && _sel == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 3),
            child: Text(
              'Drag the white handles to trim. Pinch to zoom.',
              key: ValueKey('timelineHint'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 11.5),
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
      double size = 20,
    }) => Material(
      key: key,
      color: const Color(0xFF1F1F23),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(
            icon,
            size: size,
            color: onTap == null ? Colors.white30 : Colors.white,
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          if (_isVideo)
            circle(
              const ValueKey('editorPlay'),
              _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
              _recording ? null : _togglePause,
              size: 22,
            )
          else
            const SizedBox(width: 34),
          Expanded(
            child: _isVideo
                ? ValueListenableBuilder<double>(
                    valueListenable: _pos,
                    builder: (_, p, _) {
                      final sp = _speed <= 0 ? 1.0 : _speed;
                      final at = (_outOffset(p) / sp).clamp(0.0, 36000.0);
                      final len = _keptLength / sp;
                      return Text(
                        '${_clock2(at)} / ${_clock2(len)}',
                        key: const ValueKey('editorTime'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
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
          const SizedBox(width: 6),
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
    if (_clipMask != null) video = MaskedBox(mask: _clipMask, child: video);
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
            if (_layers.isNotEmpty)
              Positioned.fill(
                child: LayerStack(
                  layers: List.of(_layers),
                  clock: _pos,
                  playing: _playingN,
                  clipSeconds: _end,
                ),
              ),
            if (_tool == _Tool.mask && _clipMask != null)
              Positioned.fill(child: _maskDrag(Size(w, h))),
            if (_tool == _Tool.layer && _layerSel != null)
              _layerHandle(Size(w, h)),
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
        height: 70,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
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
                const ValueKey('tool_split'),
                Icons.content_cut_rounded,
                _cuts.isEmpty ? 'Split' : 'Parts',
                _Tool.split,
              ),
              _toolButton(
                const ValueKey('tool_layer'),
                Icons.layers_outlined,
                'Overlay',
                _Tool.layer,
              ),
              _toolButton(
                const ValueKey('tool_mask'),
                Icons.vignette_outlined,
                'Mask',
                _Tool.mask,
              ),
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
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(12),
        onTap: _busy || locked ? null : onTap,
        child: SizedBox(
          width: 60,
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.topCenter,
                children: [
                  Container(
                    width: 40,
                    height: 34,
                    decoration: BoxDecoration(
                      color: on
                          ? AppTheme.volt.withValues(alpha: 0.16)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      icon,
                      size: 22,
                      color: locked ? Colors.white30 : fg,
                    ),
                  ),
                  if (badge != null)
                    Positioned(
                      top: -6,
                      right: -4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF5B6CFF),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          badge,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 8.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
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
            height: compact ? 124 : 172,
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
            onRangeStart: _trimStart,
            onRangeEnd: _trimEnd,
            onTouch: _timelineTouched,
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
  // ---- split ----

  Widget _splitTools() {
    final segs = _segs;
    final total = (_end - _start).clamp(0.001, 1e9);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      child: Column(
        key: const ValueKey('splitTools'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 40,
            child: Row(
              children: [
                for (var i = 0; i < segs.length; i++)
                  Expanded(
                    flex: math.max(
                      1,
                      ((segs[i].$2 - segs[i].$1) / total * 1000).round(),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1.5),
                      child: InkWell(
                        key: ValueKey('seg_$i'),
                        borderRadius: BorderRadius.circular(8),
                        onTap: segs.length > 1
                            ? () => _toggleSeg(segs[i])
                            : null,
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _isRemoved(segs[i])
                                ? Colors.white10
                                : AppTheme.volt.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: FittedBox(
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: _isRemoved(segs[i])
                                  ? const Icon(
                                      Icons.close_rounded,
                                      color: Colors.white54,
                                      size: 18,
                                    )
                                  : Text(
                                      _clock2(
                                        (segs[i].$2 - segs[i].$1).toDouble(),
                                      ),
                                      style: const TextStyle(
                                        color: Colors.black,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            segs.length > 1
                ? 'Tap a part to take it out or put it back.'
                : 'Move the playhead and tap Split.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38, fontSize: 11.5),
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.tonalIcon(
                key: const ValueKey('splitHere'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: _splitHere,
                icon: const Icon(Icons.content_cut_rounded, size: 16),
                label: const Text('Split'),
              ),
              const SizedBox(width: 8),
              if (_cuts.isNotEmpty)
                TextButton(
                  key: const ValueKey('splitJoin'),
                  style: TextButton.styleFrom(minimumSize: const Size(0, 34)),
                  onPressed: _joinAll,
                  child: const Text('Join all'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ---- overlay layers ----

  Widget _mini(
    Key key,
    String label,
    double v,
    double min,
    double max,
    ValueChanged<double> on,
  ) => Row(
    children: [
      SizedBox(
        width: 58,
        child: Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 11.5),
        ),
      ),
      Expanded(
        child: SliderTheme(
          data: const SliderThemeData(
            trackHeight: 2,
            overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
          ),
          child: Slider(
            key: key,
            value: v.clamp(min, max).toDouble(),
            min: min,
            max: max,
            activeColor: AppTheme.volt,
            onChanged: on,
          ),
        ),
      ),
    ],
  );

  Widget _chip(Key key, String label, bool on, VoidCallback tap) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: ChoiceChip(
      key: key,
      label: Text(label, style: const TextStyle(fontSize: 11.5)),
      selected: on,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: (_) => tap(),
    ),
  );

  Future<void> _addLayer(bool video) async {
    final hook = debugPickLayer;
    File? file;
    double aspect = 1;
    if (hook != null) {
      final r = await hook(video);
      if (r == null) return;
      file = r.$1;
      aspect = r.$2;
    } else {
      final x = video
          ? await ImagePicker().pickVideo(source: ImageSource.gallery)
          : await ImagePicker().pickImage(source: ImageSource.gallery);
      if (x == null) return;
      file = File(x.path);
      try {
        if (video) {
          final info = await VideoCompress.getMediaInfo(x.path);
          var w = (info.width ?? 0).toDouble(),
              h = (info.height ?? 0).toDouble();
          if ((info.orientation ?? 0) % 180 == 90) (w, h) = (h, w);
          if (w > 0 && h > 0) aspect = w / h;
        } else {
          final sz = await PhotoEditor.probeSize(file);
          if (sz != null && sz.height > 0) aspect = sz.width / sz.height;
        }
      } catch (_) {
        // keeps a square frame
      }
    }
    if (!mounted) return;
    setState(() {
      _layers.add(MediaLayer(ref: file!.path, video: video, aspect: aspect));
      _layerSel = _layers.length - 1;
      _layerTab = 0;
    });
  }

  void _setLayer(MediaLayer Function(MediaLayer l) f) {
    final i = _layerSel;
    if (i == null || i >= _layers.length) return;
    setState(() => _layers[i] = f(_layers[i]));
  }

  Widget _layerTools() {
    final i = _layerSel;
    final l = i != null && i < _layers.length ? _layers[i] : null;
    const tabs = ['Blend', 'Key', 'Mask', 'Animate', 'Time'];
    return Padding(
      key: const ValueKey('layerTools'),
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (var k = 0; k < _layers.length; k++)
                  _chip(
                    ValueKey('layerChip$k'),
                    '${_layers[k].video ? 'Video' : 'Photo'} ${k + 1}',
                    k == i,
                    () => setState(() => _layerSel = k == i ? null : k),
                  ),
                ActionChip(
                  key: const ValueKey('layerAddPhoto'),
                  avatar: const Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 16,
                  ),
                  label: const Text('Photo', style: TextStyle(fontSize: 11.5)),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _addLayer(false),
                ),
                const SizedBox(width: 6),
                ActionChip(
                  key: const ValueKey('layerAddVideo'),
                  avatar: const Icon(Icons.video_call_outlined, size: 16),
                  label: const Text('Video', style: TextStyle(fontSize: 11.5)),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _addLayer(true),
                ),
              ],
            ),
          ),
          if (l == null)
            const Expanded(
              child: Center(
                child: Text(
                  'Add a photo or video on top of the clip, then drag and pinch it.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white38, fontSize: 11.5),
                ),
              ),
            )
          else ...[
            SizedBox(
              height: 30,
              child: Row(
                children: [
                  for (var t = 0; t < tabs.length; t++)
                    Expanded(
                      child: InkWell(
                        key: ValueKey('layerTab$t'),
                        onTap: () async {
                          setState(() => _layerTab = t);
                          if (t == 3) {
                            final a = await showMotionSheet(context, l.anim);
                            if (a == null || !mounted) return;
                            _setLayer(
                              (x) => a.isEmpty
                                  ? x.copyWith(clearAnim: true)
                                  : x.copyWith(anim: a),
                            );
                          }
                        },
                        child: Center(
                          child: Text(
                            tabs[t],
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: _layerTab == t
                                  ? AppTheme.volt
                                  : Colors.white60,
                            ),
                          ),
                        ),
                      ),
                    ),
                  IconButton(
                    key: const ValueKey('layerDelete'),
                    tooltip: 'Delete',
                    visualDensity: VisualDensity.compact,
                    color: AppTheme.coral,
                    icon: const Icon(Icons.delete_outline_rounded, size: 20),
                    onPressed: () => setState(() {
                      _layers.removeAt(i!);
                      _layerSel = null;
                    }),
                  ),
                ],
              ),
            ),
            Expanded(child: _layerTabBody(l)),
          ],
        ],
      ),
    );
  }

  Widget _layerTabBody(MediaLayer l) {
    switch (_layerTab) {
      case 1:
        final k = l.chroma;
        const keys = <(int, String)>[
          (0xFF00FF00, 'Green'),
          (0xFF0000FF, 'Blue'),
          (0xFF000000, 'Black'),
          (0xFFFFFFFF, 'White'),
        ];
        return Column(
          children: [
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _chip(
                    const ValueKey('key_off'),
                    'Off',
                    k == null,
                    () => _setLayer((x) => x.copyWith(clearChroma: true)),
                  ),
                  for (final c in keys)
                    _chip(
                      ValueKey('key_${c.$2.toLowerCase()}'),
                      c.$2,
                      k?.color == c.$1,
                      () => _setLayer(
                        (x) => x.copyWith(
                          chroma: (x.chroma ?? const ChromaKey()).copyWith(
                            color: c.$1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (k != null) ...[
              _mini(
                const ValueKey('keyStrength'),
                'Strength',
                k.strength,
                0,
                1,
                (v) => _setLayer(
                  (x) => x.copyWith(chroma: k.copyWith(strength: v)),
                ),
              ),
              _mini(
                const ValueKey('keySoft'),
                'Soft',
                k.soft,
                0,
                1,
                (v) =>
                    _setLayer((x) => x.copyWith(chroma: k.copyWith(soft: v))),
              ),
            ],
          ],
        );
      case 2:
        return _maskControls(
          l.mask,
          (m) => _setLayer(
            (x) =>
                m == null ? x.copyWith(clearMask: true) : x.copyWith(mask: m),
          ),
          'lm',
        );
      case 3:
        final a = l.anim;
        return Center(
          child: Text(
            a == null || a.isEmpty
                ? 'No animation. Tap Animate to choose one.'
                : 'In: ${kMotionKinds[a.inn] ?? 'none'}   Out: ${kMotionKinds[a.out] ?? 'none'}',
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
        );
      case 4:
        String t(double s) => s < 0 ? 'end' : _clock2(s);
        return Column(
          children: [
            Text(
              'Shown ${t(l.from)} to ${t(l.to)}',
              key: const ValueKey('layerTime'),
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  key: const ValueKey('layerFrom'),
                  style: TextButton.styleFrom(minimumSize: const Size(0, 34)),
                  onPressed: () => _setLayer((x) {
                    final p = _pos.value;
                    return x.copyWith(
                      from: p,
                      to: x.to >= 0 && x.to <= p ? -1 : x.to,
                    );
                  }),
                  child: const Text('Start here'),
                ),
                TextButton(
                  key: const ValueKey('layerTo'),
                  style: TextButton.styleFrom(minimumSize: const Size(0, 34)),
                  onPressed: () => _setLayer((x) {
                    final p = _pos.value;
                    return p > x.from ? x.copyWith(to: p) : x;
                  }),
                  child: const Text('End here'),
                ),
                TextButton(
                  key: const ValueKey('layerAll'),
                  style: TextButton.styleFrom(minimumSize: const Size(0, 34)),
                  onPressed: () =>
                      _setLayer((x) => x.copyWith(from: 0, to: -1)),
                  child: const Text('Whole clip'),
                ),
              ],
            ),
          ],
        );
    }
    return Column(
      children: [
        SizedBox(
          height: 34,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final e in kBlendModes.entries)
                _chip(
                  ValueKey('blend_${e.key}'),
                  e.value.$1,
                  l.blend == e.key,
                  () => _setLayer((x) => x.copyWith(blend: e.key)),
                ),
            ],
          ),
        ),
        _mini(
          const ValueKey('layerOpacity'),
          'Opacity',
          l.opacity,
          0.05,
          1,
          (v) => _setLayer((x) => x.copyWith(opacity: v)),
        ),
      ],
    );
  }

  /// Shape chips, invert, size and soft edge for a mask.
  Widget _maskControls(LayerMask? m, ValueChanged<LayerMask?> on, String id) {
    return Column(
      children: [
        SizedBox(
          height: 34,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _chip(ValueKey('${id}_none'), 'None', m == null, () => on(null)),
              for (final e in kMaskShapes.entries)
                _chip(
                  ValueKey('${id}_${e.key}'),
                  e.value,
                  m?.shape == e.key,
                  () => on((m ?? const LayerMask()).copyWith(shape: e.key)),
                ),
              if (m != null)
                _chip(
                  ValueKey('${id}_invert'),
                  'Invert',
                  m.invert,
                  () => on(m.copyWith(invert: !m.invert)),
                ),
            ],
          ),
        ),
        if (m != null) ...[
          _mini(
            ValueKey('${id}_size'),
            'Size',
            m.size,
            0.05,
            2,
            (v) => on(m.copyWith(size: v)),
          ),
          _mini(
            ValueKey('${id}_soft'),
            'Soft',
            m.feather,
            0,
            0.5,
            (v) => on(m.copyWith(feather: v)),
          ),
        ],
      ],
    );
  }

  Widget _maskTools() => Padding(
    key: const ValueKey('maskTools'),
    padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
    child: _maskControls(
      _clipMask,
      (m) => setState(() => _clipMask = m),
      'mask',
    ),
  );

  /// Drag over the picture moves the clip's mask; pinch changes its size.
  Widget _maskDrag(Size box) {
    double base = 1;
    return GestureDetector(
      key: const ValueKey('maskDrag'),
      behavior: HitTestBehavior.opaque,
      onScaleStart: (_) => base = _clipMask?.size ?? 1,
      onScaleUpdate: (d) {
        final m = _clipMask;
        if (m == null) return;
        setState(() {
          _clipMask = m.copyWith(
            cx: (m.cx + d.focalPointDelta.dx / box.width).clamp(0.0, 1.0),
            cy: (m.cy + d.focalPointDelta.dy / box.height).clamp(0.0, 1.0),
            size: d.pointerCount > 1
                ? (base * d.scale).clamp(0.05, 2.0)
                : m.size,
          );
        });
      },
    );
  }

  /// A frame on the selected layer: drag to move, pinch to size and turn.
  Widget _layerHandle(Size box) {
    final i = _layerSel!;
    if (i >= _layers.length) return const SizedBox.shrink();
    final l = _layers[i];
    final s = layerSize(l, box);
    return Positioned(
      left: l.dx * box.width - s.width / 2,
      top: l.dy * box.height - s.height / 2,
      width: s.width,
      height: s.height,
      child: Transform.rotate(
        angle: l.turns * 2 * math.pi,
        child: GestureDetector(
          key: const ValueKey('layerHandle'),
          behavior: HitTestBehavior.opaque,
          onScaleStart: (_) {
            _layerBaseScale = l.scale;
            _layerBaseTurns = l.turns;
          },
          onScaleUpdate: (d) => _setLayer(
            (x) => x.copyWith(
              dx: (x.dx + d.focalPointDelta.dx / box.width).clamp(0.0, 1.0),
              dy: (x.dy + d.focalPointDelta.dy / box.height).clamp(0.0, 1.0),
              scale: d.pointerCount > 1
                  ? (_layerBaseScale * d.scale).clamp(0.1, 3.0)
                  : x.scale,
              turns: d.pointerCount > 1
                  ? _layerBaseTurns + d.rotation / (2 * math.pi)
                  : x.turns,
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 1.5),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      ),
    );
  }

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
    required this.cuts,
    required this.removed,
    required this.layers,
    required this.mask,
  });

  final List<int> cuts;
  final Set<int> removed;
  final List<MediaLayer> layers;
  final LayerMask? mask;

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
      '${o.text}|${o.dx}|${o.dy}|${o.scale}|${o.color}|${o.pill}|${o.emoji}|${o.image}|${o.from}|${o.to}|${o.anim?.toMap()}',
    cuts.join(','),
    (removed.toList()..sort()).join(','),
    for (final l in layers) l.toMap().toString(),
    mask?.toMap().toString(),
  ].join('~');
}
