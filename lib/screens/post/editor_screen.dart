import 'dart:async';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/finish.dart';
import '../../models/music.dart';
import '../../models/story.dart';
import '../../services/music_player.dart';
import '../../services/overlay_painter.dart';
import '../../services/photo_edit.dart';
import '../../services/playhead.dart';
import '../../widgets/music_widgets.dart';
import '../../widgets/overlay_tools.dart';
import '../../widgets/trim_timeline.dart';
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

  /// Longest part of a video that may be kept (null = no limit).
  final int? maxSeconds;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

enum _Tool { filters, adjust, crop }

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
  final List<Uint8List?> _frames = List<Uint8List?>.filled(10, null);
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
    final m = _music;
    if (m != null) unawaited(_startPlayer(m));
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
        _rangeN.value = (_start, _end);
      });
      await c.setLooping(false);
      await c.setVolume(_mute ? 0 : 1);
      c.addListener(_tick);
      unawaited(_loadFrames());
      await c.seekTo(Duration(seconds: _start.round()));
      _smooth.seek(_start, _clock.elapsed);
      _pos.value = _start;
      await c.play();
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
    _looping = true;
    _smooth.seek(_start, _clock.elapsed);
    _pos.value = _start;
    c
        .seekTo(Duration(milliseconds: (_start * 1000).round()))
        .then((_) => c.play())
        .whenComplete(() => _looping = false);
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
    _proxy?.file.delete().ignore();
    super.dispose();
  }

  // ------------------------------------------------------------------- audio

  Future<void> _startPlayer(MusicTrack t) async {
    final old = _player;
    _player = null;
    await old?.dispose();
    final p = MusicPlayer(t);
    await p.init(volume: 0.8);
    if (!mounted || _music?.id != t.id) {
      await p.dispose();
      return;
    }
    _player = p;
    if (!_paused) await p.play();
  }

  Future<void> _audio() async {
    _player?.pause();
    final t = await pickMusic(context, currentId: _music?.id);
    if (!mounted) return;
    if (t == null) {
      if (!_paused) _player?.play();
      return;
    }
    setState(() => _music = t);
    await _startPlayer(t);
  }

  Future<void> _removeAudio() async {
    final old = _player;
    _player = null;
    setState(() => _music = null);
    await old?.dispose();
  }

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
    } else {
      c.play();
      _player?.play();
    }
  }

  Future<void> _toggleMute() async {
    setState(() => _mute = !_mute);
    await _c?.setVolume(_mute ? 0 : 1);
  }

  void _applyRange(double s, double e, bool startMoved) {
    _start = s.clamp(0, _total - 1).toDouble();
    _end = e.clamp(_start + 1, _total.toDouble()).toDouble();
    _rangeN.value = (_start, _end);
    // the picture follows the handle that is being moved
    _scrubTo(startMoved ? _start : _end - 1);
  }

  /// Moves the picture (and the playhead) to [sec] without flooding the player with seeks.
  void _scrubTo(double sec) {
    _smooth.seek(sec, _clock.elapsed);
    _pos.value = sec;
    _seek.request(Duration(milliseconds: (sec * 1000).round()));
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

  void _reset() {
    setState(() {
      _e = PhotoEdits();
      _preset = 0;
      _overlays.clear();
      _sel = null;
      if (_isVideo) {
        _start = 0;
        _end = widget.maxSeconds == null
            ? _total.toDouble()
            : _total.clamp(1, widget.maxSeconds!).toDouble();
        _mute = false;
        _c?.setVolume(1);
        _rangeN.value = (_start, _end);
      }
    });
  }

  // ------------------------------------------------------------------- done

  Future<void> _done() async {
    if (_busy) return;
    if (_isVideo) {
      final ve = VideoEdits(
        start: _start.round(),
        end: _end.round(),
        total: _total,
        mute: _mute,
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
            appBar: AppBar(
              backgroundColor: Colors.black,
              leading: IconButton(
                key: const ValueKey('editorClose'),
                icon: const Icon(Icons.close_rounded),
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
              ),
              actions: [
                TextButton(
                  key: const ValueKey('editorReset'),
                  onPressed: _busy || !ready ? null : _reset,
                  style: TextButton.styleFrom(foregroundColor: Colors.white70),
                  child: const Text('Reset'),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8, left: 2),
                  child: TextButton(
                    key: const ValueKey('editorDone'),
                    onPressed: _busy || !ready ? null : _done,
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: AppTheme.volt,
                            ),
                          )
                        : const Text(
                            'Done',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                  ),
                ),
              ],
            ),
            body: _body(context),
          ),
        ),
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
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: LayoutBuilder(builder: _preview),
          ),
        ),
        _selectionBar(),
        if (_isVideo) _timeline(),
        _panel(context),
      ],
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
    final aspect = size.height == 0 ? 16 / 9 : size.width / size.height;
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
    return Center(
      child: SizedBox(
        width: w,
        height: h,
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
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_tool != null)
            SizedBox(
              height: _isVideo ? 130 : 150,
              child: switch (_tool!) {
                _Tool.crop => _cropTools(),
                _Tool.filters => _filterTools(),
                _Tool.adjust => _adjustTools(),
              },
            ),
          Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Colors.white12)),
            ),
            height: 74,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                _actionButton(
                  const ValueKey('tool_audio'),
                  Icons.music_note_rounded,
                  _music == null ? 'Audio' : _music!.title,
                  _audio,
                  on: _music != null,
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
                _actionButton(
                  const ValueKey('tool_stickers'),
                  Icons.emoji_emotions_outlined,
                  'Stickers',
                  _addSticker,
                ),
                _toolButton(
                  const ValueKey('tool_filters'),
                  Icons.auto_awesome_rounded,
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
                  _actionButton(
                    const ValueKey('tool_mute'),
                    _mute ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                    _mute ? 'Muted' : 'Mute',
                    _toggleMute,
                    on: _mute,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 4),
        ],
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
    // on a video a second tap closes the tool again, so the timeline keeps its room
    () => setState(() => _tool = (_isVideo && _tool == t) ? null : t),
    on: _tool == t,
  );

  Widget _actionButton(
    Key key,
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool on = false,
  }) {
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(14),
      onTap: _busy ? null : onTap,
      child: SizedBox(
        width: 78,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 26, color: on ? AppTheme.volt : Colors.white),
            const SizedBox(height: 5),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: on ? AppTheme.volt : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _laneLabel(StoryOverlay o) {
    if (o.isImage) return 'GIF';
    final t = o.text.trim();
    return t.isEmpty ? (o.emoji ? 'Sticker' : 'Text') : t;
  }

  /// Always in view for a video: the frames, the kept part, and one lane each for the audio,
  /// every text and every sticker.
  Widget _timeline() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      child: RepaintBoundary(
        child: ListenableBuilder(
          listenable: Listenable.merge([_rangeN, _ovTick, _framesTick]),
          builder: (context, _) {
            final r = _rangeN.value;
            return TrimTimeline(
              total: _total,
              start: r.$1,
              end: r.$2,
              position: _pos,
              frames: _frames,
              maxSeconds: widget.maxSeconds,
              audioLabel: _music?.title,
              lanes: [
                for (var i = 0; i < _overlays.length; i++)
                  TimelineLane(
                    kind: _overlays[i].emoji || _overlays[i].isImage
                        ? LaneKind.sticker
                        : LaneKind.text,
                    label: _laneLabel(_overlays[i]),
                    from: _overlays[i].from,
                    to: _overlays[i].to,
                    selected: _sel == i,
                  ),
              ],
              onLaneTap: (i) {
                if (_sel != i) setState(() => _sel = i);
              },
              onLaneRange: (i, from, to) {
                if (i >= _overlays.length) return;
                _overlays[i] = _overlays[i].copyWith(from: from, to: to);
                _ovTick.value++;
              },
              onRange: (s, e, startMoved) => _applyRange(s, e, startMoved),
              onSeek: _scrubTo,
            );
          },
        ),
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
