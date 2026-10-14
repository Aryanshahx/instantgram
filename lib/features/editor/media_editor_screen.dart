import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';

import '../../core/services/media_service.dart';
import '../../core/services/music_player.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/time_ago.dart';
import '../../shared/models/post.dart';
import '../../shared/widgets/video_extras.dart';
import '../post/presentation/create_post_screen.dart';
import 'edit_models.dart';
import 'filters.dart';
import 'photo_render.dart';
import 'video_frames.dart';

/// Opens the editor for picked media, then the share screen.
Future<void> openEditor(
  BuildContext context,
  List<PickedMedia> media,
  ComposeMode mode,
) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MediaEditorScreen(media: media, mode: mode),
    ),
  );
}

// v0.12: + split, music (was at the top), voice over, stickers
enum _Tool {
  trim,
  split,
  music,
  voice,
  text,
  stickers,
  filters,
  adjust,
  crop,
  sound,
}

/// v0.12: emoji stickers.
const List<String> kStickers = [
  '😂', '😍', '🔥', '❤️', '👍', '🎉', '😎', '🥳', '😭', '😮', '🤩', '💯', //
  '✨', '🌟', '💖', '🙌', '👏', '🤣', '😘', '🥰', '😜', '🤔', '😴', '🤯', //
  '😡', '💀', '👀', '🙏', '💪', '🎂', '🎵', '📍', '☀️', '🌈', '🌙', '⚡', //
  '🍕', '☕', '⚽', '🏆', '🚀', '💎', '🌸', '🐶', '🐱', '🦋', '💔', '🤝', //
];

enum _Adjust {
  brightness('Brightness', Icons.wb_sunny_outlined),
  contrast('Contrast', Icons.contrast),
  saturation('Saturation', Icons.palette_outlined),
  warmth('Warmth', Icons.thermostat_outlined),
  fade('Fade', Icons.blur_on);

  const _Adjust(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Advanced editor: filters, adjust, crop / rotate, text, stickers (photos)
/// and trim, split, music, voice over, text, stickers, filters, adjust,
/// sound (videos), with a timeline for videos (v0.12).
class MediaEditorScreen extends StatefulWidget {
  const MediaEditorScreen({
    super.key,
    required this.media,
    required this.mode,
    this.onDone,
  });

  final List<PickedMedia> media;
  final ComposeMode mode;

  /// Tests: called with the result instead of opening the share screen.
  final ValueChanged<List<EditedMedia>>? onDone;

  @override
  State<MediaEditorScreen> createState() => _MediaEditorScreenState();
}

class _MediaEditorScreenState extends State<MediaEditorScreen> {
  late final List<EditItem> _items = widget.media
      .map((m) => EditItem(m, mode: widget.mode))
      .toList();
  int _index = 0;
  late _Tool _tool = _items.first.isVideo ? _Tool.trim : _Tool.filters;
  _Adjust _adjust = _Adjust.brightness;
  bool _exporting = false;
  bool _showGrid = false;

  VideoPlayerController? _video;
  bool _videoReady = false;
  String? _videoError;

  /// Music from phone storage (posts and clips only).
  PickedAudio? _audio;
  bool _audioPlaying = false;
  bool get _musicAllowed => widget.mode != ComposeMode.story;

  /// Voice over: posts and clips only (not moments).
  bool get _voiceAllowed => widget.mode != ComposeMode.story;

  // v0.12: selected text / sticker on a video, voice over
  int? _selOverlay;
  double _gestureSize = 0.08;
  DateTime _lastSkip = DateTime.fromMillisecondsSinceEpoch(0);
  VoiceTrack? _voiceTrack;
  AudioRecorder? _rec;
  bool _recording = false;
  int _recStartPlayed = 0;
  DateTime? _recAt;
  Timer? _recTimer;
  int _recMs = 0;
  bool _musicBeforeRec = false;
  bool _scrubWasPlaying = false;

  EditItem get _item => _items[_index];

  List<_Tool> get _tools => _item.isVideo
      ? [
          _Tool.trim,
          _Tool.split,
          if (_musicAllowed) _Tool.music,
          if (_voiceAllowed) _Tool.voice,
          _Tool.text,
          _Tool.stickers,
          _Tool.filters,
          _Tool.adjust,
          _Tool.sound,
        ]
      : [
          _Tool.filters,
          _Tool.adjust,
          _Tool.crop,
          _Tool.text,
          _Tool.stickers,
          if (_musicAllowed) _Tool.music,
        ];

  @override
  void initState() {
    super.initState();
    _openItem();
  }

  @override
  void dispose() {
    MusicPlayer.instance.stop(_kPreview);
    _recTimer?.cancel();
    if (_recording) unawaited(_rec?.cancel());
    _rec?.dispose();
    _voiceTrack?.dispose();
    _video?.dispose();
    for (final i in _items) {
      i.zoom?.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------- load

  Future<void> _openItem() async {
    final item = _item;
    if (!_tools.contains(_tool)) _tool = _tools.first;
    final old = _video;
    _video = null;
    _videoReady = false;
    _videoError = null;
    _selOverlay = null;
    _voiceTrack?.dispose();
    _voiceTrack = null;
    old?.dispose();
    if (item.isVideo) {
      await _loadVideo(item);
    } else {
      _loadPhotoSize(item);
    }
  }

  void _loadPhotoSize(EditItem item) {
    if (item.natural != null) return;
    final stream = FileImage(item.file).resolve(ImageConfiguration.empty);
    late ImageStreamListener l;
    l = ImageStreamListener(
      (info, _) {
        item.natural = Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
        stream.removeListener(l);
        if (mounted) setState(() {});
      },
      onError: (e, _) {
        stream.removeListener(l);
        item.natural = const Size(1000, 1000);
        if (mounted) setState(() {});
      },
    );
    stream.addListener(l);
  }

  Future<void> _loadVideo(EditItem item) async {
    final c = VideoPlayerController.file(item.file);
    _video = c;
    setState(() {});
    try {
      await c.initialize();
      if (!mounted || _video != c) return;
      item.durationMs = c.value.duration.inMilliseconds;
      item.videoAspect = c.value.aspectRatio > 0 ? c.value.aspectRatio : 9 / 16;
      final max = maxVideoMs(widget.mode);
      if (item.trimEnd == 0 || item.trimEnd > item.durationMs) {
        item.trimEnd = item.durationMs > max ? max : item.durationMs;
      }
      await c.setLooping(false);
      await c.setVolume(item.muted || _audioPlaying ? 0 : 1);
      await c.seekTo(Duration(milliseconds: item.trimStart));
      c.addListener(_loop);
      setState(() => _videoReady = true);
      _attachVoicePreview();
      c.play();
      _makeThumbs(item);
    } catch (e) {
      if (mounted) setState(() => _videoError = 'Could not open this video');
    }
  }

  /// Keep playing inside the trim range and jump over removed parts.
  /// Paused = stays where you put the white line (also on a removed part).
  void _loop() {
    final c = _video;
    if (c == null || !c.value.isInitialized) return;
    final item = _item;
    final v = c.value;
    final pos = v.position.inMilliseconds;
    final cuts = item.activeCuts;
    final end = VideoTime.playableEnd(item.endMs, cuts);
    final start = VideoTime.firstPlayable(item.trimStart, cuts);
    if (_recording) {
      if (pos >= end - 60 || v.isCompleted) unawaited(_stopVoice());
      return;
    }
    if (!v.isPlaying && !v.isCompleted) return;
    if (pos >= end - 30 || v.isCompleted) {
      c.seekTo(Duration(milliseconds: start));
      if (!c.value.isPlaying) c.play();
      return;
    }
    final to = VideoTime.skipTo(pos, cuts);
    final now = DateTime.now();
    if (to != null && now.difference(_lastSkip).inMilliseconds > 300) {
      _lastSkip = now;
      c.seekTo(Duration(milliseconds: to >= end ? start : to));
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------------------------------------------------------- voice

  /// Preview of the voice over in time with the video.
  void _attachVoicePreview() {
    _voiceTrack?.dispose();
    _voiceTrack = null;
    final c = _video;
    final item = _item;
    if (c == null || !item.isVideo || !item.hasVoice || _recording) return;
    _voiceTrack = VoiceTrack(item.videoEdits)..attach(c);
  }

  Future<void> _startVoice() async {
    final c = _video;
    if (c == null || !_videoReady || _recording) return;
    final item = _item;
    final r = _rec ??= AudioRecorder();
    try {
      if (!await r.hasPermission()) {
        _snack('Allow the microphone to record a voice over.');
        return;
      }
      final dir = await getApplicationDocumentsDirectory();
      unawaited(_sweepOldVoice(dir));
      final path =
          '${dir.path}/voiceover_${DateTime.now().millisecondsSinceEpoch}.m4a';
      final cuts = item.activeCuts;
      final end = VideoTime.playableEnd(item.endMs, cuts);
      var pos = c.value.position.inMilliseconds;
      if (pos < item.trimStart || pos >= end - 500) pos = item.trimStart;
      pos = VideoTime.firstPlayable(pos, cuts);
      _voiceTrack?.dispose();
      _voiceTrack = null;
      _musicBeforeRec = _audioPlaying;
      if (_audioPlaying) MusicPlayer.instance.pause(_kPreview);
      await c.pause();
      await c.seekTo(Duration(milliseconds: pos));
      await c.setVolume(0); // only your voice is recorded
      await r.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 96000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );
      if (!mounted) return;
      _recStartPlayed = VideoTime.playedAt(pos, item.trimStart, cuts);
      _recAt = DateTime.now();
      HapticFeedback.mediumImpact();
      setState(() {
        _recording = true;
        _recMs = 0;
      });
      c.play();
      _recTimer?.cancel();
      _recTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted || _recAt == null) return;
        setState(
          () => _recMs = DateTime.now().difference(_recAt!).inMilliseconds,
        );
      });
    } catch (e) {
      _snack("Couldn't record: $e");
    }
  }

  Future<void> _stopVoice({bool keep = true}) async {
    if (!_recording) return;
    _recTimer?.cancel();
    final ms = DateTime.now().difference(_recAt!).inMilliseconds;
    setState(() => _recording = false);
    final c = _video;
    final item = _item;
    unawaited(c?.pause());
    String? path;
    try {
      path = keep ? await _rec?.stop() : null;
      if (!keep) await _rec?.cancel();
    } catch (_) {}
    if (_musicBeforeRec) MusicPlayer.instance.resume(_kPreview);
    await c?.setVolume(item.muted || _audioPlaying ? 0 : 1);
    if (!mounted) return;
    if (path == null || ms < 700) {
      if (path != null) _deleteFile(path);
      if (keep) _snack('Too short. Tap record and speak while the video plays.');
      return;
    }
    final room = math.max(0, item.playedMs - _recStartPlayed);
    final old = item.voicePath;
    setState(() {
      item.voicePath = path!;
      item.voiceStartMs = _recStartPlayed;
      item.voiceDurMs = math.min(ms, room);
    });
    if (old.isNotEmpty && old != path) _deleteFile(old);
    _attachVoicePreview();
    c?.seekTo(
      Duration(
        milliseconds: VideoTime.sourceAt(
          item.voiceStartMs,
          item.trimStart,
          item.activeCuts,
        ),
      ),
    );
  }

  void _deleteVoice() {
    final item = _item;
    final old = item.voicePath;
    _voiceTrack?.dispose();
    _voiceTrack = null;
    setState(() {
      item.voicePath = '';
      item.voiceStartMs = 0;
      item.voiceDurMs = 0;
    });
    if (old.isNotEmpty) _deleteFile(old);
  }

  void _deleteFile(String path) {
    unawaited(
      File(path).delete().then((_) {}, onError: (Object _) {}),
    );
  }

  /// Old recordings that were never posted (older than 3 days).
  Future<void> _sweepOldVoice(Directory dir) async {
    try {
      final limit = DateTime.now().subtract(const Duration(days: 3));
      await for (final f in dir.list()) {
        if (f is File &&
            f.path.contains('voiceover_') &&
            (await f.lastModified()).isBefore(limit)) {
          await f.delete();
        }
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------- split

  int get _pos => _video?.value.position.inMilliseconds ?? _item.trimStart;

  void _splitHere() {
    final item = _item;
    final p = _pos;
    if (p <= item.trimStart + 300 || p >= item.endMs - 300) {
      _snack('Move the white line inside the video, then tap Split.');
      return;
    }
    if (item.splits.any((x) => (x - p).abs() < 300)) {
      _snack('There is already a split here.');
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => item.splits.add(p));
  }

  void _deletePart() {
    final item = _item;
    final seg = item.segmentAt(_pos);
    if (seg == null || item.segments.length < 2) {
      _snack('Split the video first, then delete a part.');
      return;
    }
    if (item.isCut(seg)) return;
    final after = VideoTime.playedMs(
      item.trimStart,
      item.endMs,
      VideoTime.normalize([...item.activeCuts, seg]),
    );
    if (after < 1000) {
      _snack("You can't delete every part.");
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => item.cuts = VideoTime.normalize([...item.cuts, seg]));
    _attachVoicePreview();
  }

  void _restorePart() {
    final item = _item;
    final seg = item.segmentAt(_pos);
    setState(() {
      if (seg != null && item.isCut(seg)) {
        // remove this part from the cuts
        final out = <VideoCut>[];
        for (final c in item.cuts) {
          if (c.endMs <= seg.startMs || c.startMs >= seg.endMs) {
            out.add(c);
            continue;
          }
          if (c.startMs < seg.startMs) out.add(VideoCut(c.startMs, seg.startMs));
          if (c.endMs > seg.endMs) out.add(VideoCut(seg.endMs, c.endMs));
        }
        item.cuts = VideoTime.normalize(out);
      } else {
        item.cuts = [];
        item.splits.clear();
      }
    });
    _attachVoicePreview();
  }

  Future<void> _makeThumbs(EditItem item) async {
    if (item.thumbs != null || item.durationMs <= 0) return;
    const n = 8;
    item.thumbs = List<Uint8List?>.filled(n, null);
    for (var i = 0; i < n; i++) {
      final t = (item.durationMs * (i + 0.5) / n).round();
      final b = await VideoFrames.bytes(item.file.path, t);
      if (!mounted) return;
      item.thumbs![i] = b;
      setState(() {});
    }
  }

  void _select(int i) {
    if (i == _index) return;
    if (_recording) unawaited(_stopVoice(keep: false));
    setState(() => _index = i);
    _openItem();
  }

  void _remove(int i) {
    if (_items.length <= 1) return;
    if (_recording) unawaited(_stopVoice(keep: false));
    final vp = _items[i].voicePath;
    if (vp.isNotEmpty) _deleteFile(vp);
    setState(() {
      _items[i].zoom?.dispose();
      _items.removeAt(i);
      if (_index >= _items.length) _index = _items.length - 1;
    });
    _openItem();
  }

  // ---------------------------------------------------------------- music

  static const String _kPreview = 'editor-preview';

  Future<void> _pickMusic() async {
    try {
      final a = await MediaService.instance.pickAudio();
      if (a == null || !mounted) return;
      setState(() => _audio = a);
      _playMusic(true);
    } catch (e) {
      if (!mounted) return;
      final msg = e is StateError ? e.message : 'Could not open music: $e';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  void _playMusic(bool on) {
    final a = _audio;
    if (a == null) return;
    setState(() => _audioPlaying = on);
    if (on) {
      MusicPlayer.instance.play(_kPreview, a.file.path);
      _video?.setVolume(0); // music replaces the video sound
    } else {
      MusicPlayer.instance.stop(_kPreview);
      _video?.setVolume(_item.muted ? 0 : 1);
    }
  }

  void _removeMusic() {
    MusicPlayer.instance.stop(_kPreview);
    setState(() {
      _audio = null;
      _audioPlaying = false;
    });
    _video?.setVolume(_item.muted ? 0 : 1);
  }

  /// v0.12: music is a tool now (was a bar at the top).
  Widget _musicPanel() {
    final a = _audio;
    if (a == null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FilledButton.icon(
            key: const ValueKey('editor-music'),
            onPressed: _pickMusic,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.lime,
              foregroundColor: Colors.black,
              textStyle: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontWeight: FontWeight.w800,
              ),
            ),
            icon: const Icon(Icons.music_note),
            label: const Text('Add music'),
          ),
          const SizedBox(height: 10),
          const Text(
            'From your phone · plays in a loop · replaces the video sound',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            key: const ValueKey('editor-music-chip'),
            padding: const EdgeInsets.only(left: 12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                const Icon(Icons.music_note, size: 18, color: AppColors.lime),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        a.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                      const Text(
                        'Plays in a loop · replaces video sound',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: _audioPlaying ? 'Pause' : 'Play',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _playMusic(!_audioPlaying),
                  icon: Icon(_audioPlaying ? Icons.pause : Icons.play_arrow),
                ),
                IconButton(
                  key: const ValueKey('editor-music-remove'),
                  tooltip: 'Remove music',
                  visualDensity: VisualDensity.compact,
                  onPressed: _removeMusic,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: _pickMusic,
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: const Text('Change music'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- export

  Future<void> _next() async {
    if (_exporting) return;
    if (_recording) await _stopVoice();
    setState(() => _exporting = true);
    try {
      final out = <EditedMedia>[];
      for (var i = 0; i < _items.length; i++) {
        final item = _items[i];
        if (item.isVideo) {
          File? preview;
          if (!kIsWeb) {
            preview = await VideoFrames.file(
              item.file.path,
              item.trimStart,
              maxWidth: 720,
              quality: 80,
            );
          }
          out.add(
            EditedMedia(
              file: item.file,
              isVideo: true,
              aspectRatio: item.videoAspect,
              edits: item.videoEdits,
              durationMs: item.playedMs,
              preview: preview,
            ),
          );
          continue;
        }
        if (!item.photoEdited) {
          final n = item.natural ?? await _naturalOf(item);
          out.add(
            EditedMedia(
              file: item.file,
              isVideo: false,
              aspectRatio: n.width / n.height,
            ),
          );
          continue;
        }
        out.add(await _renderEdited(item, i));
      }
      if (!mounted) return;
      if (widget.onDone != null) {
        widget.onDone!(out);
      } else {
        _playMusic(false);
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                CreatePostScreen(items: out, mode: widget.mode, audio: _audio),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not prepare media: $e')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<Size> _naturalOf(EditItem item) async {
    final c = Completer<Size>();
    final stream = FileImage(item.file).resolve(ImageConfiguration.empty);
    late ImageStreamListener l;
    l = ImageStreamListener(
      (info, _) {
        if (!c.isCompleted) {
          c.complete(
            Size(info.image.width.toDouble(), info.image.height.toDouble()),
          );
        }
        stream.removeListener(l);
      },
      onError: (e, _) {
        if (!c.isCompleted) c.complete(const Size(1, 1));
        stream.removeListener(l);
      },
    );
    stream.addListener(l);
    final s = await c.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => const Size(1, 1),
    );
    item.natural ??= s;
    return s;
  }

  /// Draws the edited photo on a canvas (crop, zoom, rotate, flip,
  /// filter, text) and saves it as a JPG.
  Future<EditedMedia> _renderEdited(EditItem item, int i) async {
    final natural = item.natural ?? await _naturalOf(item);
    final aspect = _targetAspect(item);
    final PhotoLayout layout;
    Matrix4 transform;
    final frame = item.frameSize, photo = item.photoSize;
    if (frame != null && photo != null && item.zoom != null) {
      layout = PhotoLayout(frame, photo);
      transform = item.zoom!.value.clone();
    } else {
      // never shown on screen: centered at zoom 1
      layout = PhotoLayout.compute(
        natural: natural,
        turns: item.turns,
        aspect: aspect,
        box: const Size(1000, 1000),
      );
      transform = layout.centered();
    }
    final bytes = await item.file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frameInfo = await codec.getNextFrame();
    codec.dispose();
    final src = frameInfo.image;
    final targetW = widget.mode == ComposeMode.story ? 1080 : 1350;
    final textScale = mounted
        ? MediaQuery.textScalerOf(context).scale(100) / 100
        : 1.0;
    final ui.Image image;
    try {
      image = await renderPhoto(
        src,
        PhotoRenderSpec(
          layout: layout,
          transform: transform,
          turns: item.turns,
          flip: item.flip,
          colorMatrix: item.color.isNone ? null : item.color.matrix,
          texts: item.texts,
          textScale: textScale,
        ),
        outWidth: targetW,
      );
    } finally {
      src.dispose();
    }
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = image.width, height = image.height;
    image.dispose();
    if (data == null) throw StateError('Could not draw the photo');
    final jpg = await compute(
      _encodeJpg,
      _Raw(data.buffer.asUint8List(), width, height),
    );
    final dir = await Directory.systemTemp.createTemp('ig_edit');
    final file = File(
      '${dir.path}/edit_${DateTime.now().millisecondsSinceEpoch}_$i.jpg',
    );
    await file.writeAsBytes(jpg, flush: true);
    return EditedMedia(
      file: file,
      isVideo: false,
      aspectRatio: layout.frame.width / layout.frame.height,
    );
  }

  // ---------------------------------------------------------------- photo frame

  double _targetAspect(EditItem item) {
    final n = item.natural ?? const Size(1, 1);
    final na = item.turns.isOdd ? n.height / n.width : n.width / n.height;
    final r = item.aspect.ratio;
    if (r != null) return r;
    return na; // "Original" keeps the real shape (no crop)
  }

  Widget _photoCanvas(EditItem item) {
    final n = item.natural;
    if (n == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    return LayoutBuilder(
      builder: (context, box) {
        final a = _targetAspect(item);
        final maxW = box.maxWidth - 24, maxH = box.maxHeight - 24;
        double fw, fh;
        if (maxW / maxH > a) {
          fh = maxH;
          fw = maxH * a;
        } else {
          fw = maxW;
          fh = maxW / a;
        }
        final na = item.turns.isOdd ? n.height / n.width : n.width / n.height;
        double cw, ch;
        if (na > a) {
          ch = fh;
          cw = fh * na;
        } else {
          cw = fw;
          ch = fw / na;
        }
        item.zoom ??= TransformationController(
          Matrix4.translationValues(-(cw - fw) / 2, -(ch - fh) / 2, 0),
        );
        // remembered for the export (same numbers as on screen)
        item.frameSize = Size(fw, fh);
        item.photoSize = Size(cw, ch);

        final photo = SizedBox(
          width: cw,
          height: ch,
          child: applyMatrix(
            item.color.isNone ? null : item.color.matrix,
            Transform(
              alignment: Alignment.center,
              transform: Matrix4.diagonal3Values(item.flip ? -1 : 1, 1, 1),
              child: RotatedBox(
                quarterTurns: item.turns % 4,
                child: Image.file(
                  item.file,
                  fit: BoxFit.fill,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
        );

        return Center(
          child: SizedBox(
            width: fw,
            height: fh,
            child: Stack(
              children: [
                RepaintBoundary(
                  child: ClipRect(
                    child: ColoredBox(
                      color: Colors.black,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: InteractiveViewer(
                              transformationController: item.zoom,
                              constrained: false,
                              minScale: 1,
                              maxScale: 5,
                              boundaryMargin: EdgeInsets.zero,
                              onInteractionStart: (_) =>
                                  setState(() => _showGrid = true),
                              onInteractionEnd: (_) => setState(() {
                                _showGrid = false;
                                item.zoomChanged = true;
                              }),
                              child: photo,
                            ),
                          ),
                          for (final t in item.texts)
                            _textLayer(item, t, fw, fh),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_showGrid || _tool == _Tool.crop)
                  const Positioned.fill(
                    child: IgnorePointer(child: CustomPaint(painter: _Grid())),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _textLayer(EditItem item, TextLayer t, double fw, double fh) {
    // v0.12: same limits as the saved photo; stickers; pinch = size
    final fs = (t.size * fw).clamp(fw * 0.02, fw * 0.5);
    final text = Text(
      t.text,
      textAlign: TextAlign.center,
      textScaler: t.sticker ? TextScaler.noScaling : null,
      style: TextStyle(
        fontFamily: AppTheme.fontFamily,
        color: t.color,
        fontSize: fs,
        fontWeight: FontWeight.w800,
        height: 1.15,
        shadows: t.background || t.sticker
            ? null
            : [Shadow(blurRadius: fs * 0.12, color: Colors.black54)],
      ),
    );
    return Positioned(
      left: t.pos.dx * fw,
      top: t.pos.dy * fh,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: GestureDetector(
          onScaleStart: (_) => _gestureSize = t.size,
          onScaleUpdate: (d) => setState(() {
            t.pos = Offset(
              (t.pos.dx + d.focalPointDelta.dx / fw).clamp(0.0, 1.0),
              (t.pos.dy + d.focalPointDelta.dy / fh).clamp(0.0, 1.0),
            );
            if (d.pointerCount > 1) {
              t.size = (_gestureSize * d.scale).clamp(0.03, 0.5);
            }
          }),
          onTap: () => t.sticker
              ? _removeSticker(item, t)
              : _editText(item, t),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: fw * 0.9),
            child: t.background
                ? Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: fs * 0.4,
                      vertical: fs * 0.15,
                    ),
                    decoration: BoxDecoration(
                      color: t.color.computeLuminance() > 0.5
                          ? Colors.black87
                          : Colors.white,
                      borderRadius: BorderRadius.circular(fs * 0.3),
                    ),
                    child: text,
                  )
                : text,
          ),
        ),
      ),
    );
  }

  Future<void> _removeSticker(EditItem item, TextLayer t) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (c) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.delete_outline, color: AppColors.like),
          title: Text('Remove ${t.text}'),
          onTap: () => Navigator.pop(c, true),
        ),
      ),
    );
    if (ok == true && mounted) setState(() => item.texts.remove(t));
  }

  void _addSticker(String emoji) {
    final item = _item;
    HapticFeedback.selectionClick();
    setState(() {
      if (item.isVideo) {
        item.overlays.add(
          VideoOverlay(
            kind: VideoOverlay.stickerKind,
            text: emoji,
            size: 0.16,
            x: 0.5,
            y: 0.42,
          ),
        );
        _selOverlay = item.overlays.length - 1;
      } else {
        item.texts.add(
          TextLayer(
            text: emoji,
            size: 0.16,
            pos: const Offset(0.5, 0.42),
            sticker: true,
          ),
        );
      }
    });
  }

  /// Video: add (index null) or change a text.
  Future<void> _editOverlay(int? index) async {
    final item = _item;
    final o = index == null ? null : item.overlays[index];
    final res = await showModalBottomSheet<_TextResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      builder: (_) => _TextSheet(
        initial: o == null
            ? null
            : _TextResult(
                text: o.text,
                color: Color(o.color),
                size: o.size,
                background: o.background,
              ),
      ),
    );
    if (res == null || !mounted) return;
    setState(() {
      if (res.delete || res.text.trim().isEmpty) {
        if (index != null) {
          item.overlays.removeAt(index);
          _selOverlay = null;
        }
        return;
      }
      final next = VideoOverlay(
        kind: VideoOverlay.textKind,
        text: res.text.trim(),
        color: res.color.toARGB32(),
        size: res.size,
        background: res.background,
        x: o?.x ?? 0.5,
        y: o?.y ?? 0.5,
        startMs: o?.startMs ?? 0,
        endMs: o?.endMs ?? 0,
      );
      if (index == null) {
        item.overlays.add(next);
        _selOverlay = item.overlays.length - 1;
      } else {
        item.overlays[index] = next;
      }
    });
  }

  Future<void> _editText(EditItem item, TextLayer? layer) async {
    final res = await showModalBottomSheet<_TextResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      builder: (_) => _TextSheet(
        initial: layer == null
            ? null
            : _TextResult(
                text: layer.text,
                color: layer.color,
                size: layer.size,
                background: layer.background,
              ),
      ),
    );
    if (res == null || !mounted) return;
    setState(() {
      if (res.delete) {
        if (layer != null) item.texts.remove(layer);
        return;
      }
      if (res.text.trim().isEmpty) {
        if (layer != null) item.texts.remove(layer);
        return;
      }
      if (layer == null) {
        item.texts.add(
          TextLayer(
            text: res.text.trim(),
            color: res.color,
            size: res.size,
            background: res.background,
          ),
        );
      } else {
        layer
          ..text = res.text.trim()
          ..color = res.color
          ..size = res.size
          ..background = res.background;
      }
    });
  }

  // ---------------------------------------------------------------- video

  Widget _videoCanvas(EditItem item) {
    final c = _video;
    if (_videoError != null) {
      return Center(
        child: Text(
          _videoError!,
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      );
    }
    if (c == null || !_videoReady) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    return GestureDetector(
      onTap: () => setState(() {
        c.value.isPlaying ? c.pause() : c.play();
      }),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: AspectRatio(
            aspectRatio: item.videoAspect,
            // v0.12: square corners (what you see is what is posted)
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  applyMatrix(
                    item.color.isNone ? null : item.color.matrix,
                    VideoPlayer(c),
                  ),
                  _overlaysOnCanvas(item, c),
                  ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: c,
                    builder: (context, v, _) => v.isPlaying
                        ? const SizedBox.shrink()
                        : Center(
                            child: Icon(
                              Icons.play_arrow_rounded,
                              size: 72,
                              color: Colors.white.withValues(alpha: 0.9),
                            ),
                          ),
                  ),
                  if (item.muted)
                    const Positioned(
                      right: 10,
                      top: 10,
                      child: Icon(Icons.volume_off, color: Colors.white),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// v0.12: texts / stickers on the video: drag = move, pinch = size,
  /// tap = select (tap again = edit text).
  Widget _overlaysOnCanvas(EditItem item, VideoPlayerController c) {
    if (item.overlays.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, box) {
        final fw = box.maxWidth, fh = box.maxHeight;
        return ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: c,
          builder: (context, v, _) {
            final ms = v.position.inMilliseconds;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                for (var i = 0; i < item.overlays.length; i++)
                  if (item.overlays[i].visibleAt(ms) || _selOverlay == i)
                    OverlayPlace(
                      key: ValueKey('ov-$i'),
                      x: item.overlays[i].x,
                      y: item.overlays[i].y,
                      width: fw,
                      height: fh,
                      child: Opacity(
                        opacity: item.overlays[i].visibleAt(ms) ? 1 : 0.4,
                        child: GestureDetector(
                          onTap: () {
                            final o = item.overlays[i];
                            if (_selOverlay == i && !o.isSticker) {
                              _editOverlay(i);
                            } else {
                              setState(() => _selOverlay = i);
                            }
                          },
                          onScaleStart: (_) => setState(() {
                            _selOverlay = i;
                            _gestureSize = item.overlays[i].size;
                          }),
                          onScaleUpdate: (d) => setState(() {
                            final o = item.overlays[i];
                            item.overlays[i] = o.copyWith(
                              x: (o.x + d.focalPointDelta.dx / fw).clamp(0, 1),
                              y: (o.y + d.focalPointDelta.dy / fh).clamp(0, 1),
                              size: d.pointerCount > 1
                                  ? (_gestureSize * d.scale).clamp(0.03, 0.5)
                                  : o.size,
                            );
                          }),
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: _selOverlay == i
                                ? BoxDecoration(
                                    border: Border.all(
                                      color: Colors.white70,
                                      width: 1,
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  )
                                : null,
                            child: OverlayView(
                              overlay: item.overlays[i],
                              frameWidth: fw,
                            ),
                          ),
                        ),
                      ),
                    ),
              ],
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------- panels

  Widget _panel() {
    switch (_tool) {
      case _Tool.filters:
        return _filtersPanel();
      case _Tool.adjust:
        return _adjustPanel();
      case _Tool.crop:
        return _cropPanel();
      case _Tool.text:
        return _item.isVideo ? _videoTextPanel() : _textPanel();
      case _Tool.trim:
        return _trimPanel();
      case _Tool.sound:
        return _soundPanel();
      case _Tool.split:
        return _splitPanel();
      case _Tool.music:
        return _musicPanel();
      case _Tool.voice:
        return _voicePanel();
      case _Tool.stickers:
        return _stickersPanel();
    }
  }

  ButtonStyle get _limeButton => FilledButton.styleFrom(
    backgroundColor: AppColors.lime,
    foregroundColor: Colors.black,
    visualDensity: VisualDensity.compact,
    textStyle: const TextStyle(
      fontFamily: AppTheme.fontFamily,
      fontWeight: FontWeight.w800,
    ),
  );

  ButtonStyle get _darkButton => OutlinedButton.styleFrom(
    foregroundColor: Colors.white,
    visualDensity: VisualDensity.compact,
    side: const BorderSide(color: AppColors.border),
    textStyle: const TextStyle(
      fontFamily: AppTheme.fontFamily,
      fontWeight: FontWeight.w700,
    ),
  );

  Widget _hint(String t) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      t,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
    ),
  );

  /// Selected text / sticker: edit, delete, show the whole video.
  Widget _overlayActions() {
    final item = _item;
    final i = _selOverlay;
    if (i == null || i >= item.overlays.length) return const SizedBox.shrink();
    final o = item.overlays[i];
    final whole = o.startMs <= item.trimStart && o.endMs == 0;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      children: [
        if (!o.isSticker)
          OutlinedButton.icon(
            style: _darkButton,
            onPressed: () => _editOverlay(i),
            icon: const Icon(Icons.edit, size: 16),
            label: const Text('Edit'),
          ),
        OutlinedButton.icon(
          key: const ValueKey('overlay-delete'),
          style: _darkButton,
          onPressed: () => setState(() {
            item.overlays.removeAt(i);
            _selOverlay = null;
          }),
          icon: const Icon(Icons.delete_outline, size: 16, color: AppColors.like),
          label: const Text('Delete'),
        ),
        if (!whole)
          OutlinedButton.icon(
            style: _darkButton,
            onPressed: () => setState(
              () => item.overlays[i] = o.copyWith(startMs: 0, endMs: 0),
            ),
            icon: const Icon(Icons.open_in_full, size: 16),
            label: const Text('Whole video'),
          ),
      ],
    );
  }

  Widget _videoTextPanel() {
    final sel = _selOverlay;
    final hasSel = sel != null &&
        sel < _item.overlays.length &&
        !_item.overlays[sel].isSticker;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FilledButton.icon(
          key: const ValueKey('video-add-text'),
          onPressed: () => _editOverlay(null),
          style: _limeButton,
          icon: const Icon(Icons.text_fields),
          label: const Text('Add text'),
        ),
        const SizedBox(height: 6),
        if (hasSel)
          _overlayActions()
        else
          _hint(
            'Drag to move · pinch to resize · on the timeline, drag the '
            'ends to choose when it shows',
          ),
      ],
    );
  }

  Widget _stickersPanel() {
    final sel = _selOverlay;
    final stickerSel = _item.isVideo &&
        sel != null &&
        sel < _item.overlays.length &&
        _item.overlays[sel].isSticker;
    return Column(
      children: [
        Expanded(
          child: GridView.count(
            key: const ValueKey('sticker-grid'),
            crossAxisCount: 2,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            children: [
              for (final e in kStickers)
                InkWell(
                  key: ValueKey('sticker-$e'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _addSticker(e),
                  child: Center(
                    child: Text(
                      e,
                      textScaler: TextScaler.noScaling,
                      style: const TextStyle(fontSize: 30),
                    ),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 34,
          child: stickerSel
              ? _overlayActions()
              : Center(
                  child: Text(
                    _item.isVideo
                        ? 'Tap to add · drag to move · pinch to resize'
                        : 'Tap to add · drag to move · pinch to resize · '
                              'tap a sticker to remove it',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _splitPanel() {
    final item = _item;
    final c = _video;
    if (!_videoReady || c == null) return _hint('Loading video…');
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: c,
      builder: (context, v, _) {
        final seg = item.segmentAt(v.position.inMilliseconds);
        final onCut = seg != null && item.isCut(seg);
        final parts = item.segments.length;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('split-here'),
                    style: _limeButton,
                    onPressed: _splitHere,
                    icon: const Icon(Icons.vertical_split, size: 18),
                    label: const Text('Split'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('split-delete'),
                    style: _darkButton,
                    onPressed: parts > 1 && !onCut ? _deletePart : null,
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: AppColors.like,
                    ),
                    label: const Text('Delete part'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('split-restore'),
                    style: _darkButton,
                    onPressed: item.cuts.isEmpty && item.splits.isEmpty
                        ? null
                        : _restorePart,
                    icon: const Icon(Icons.undo, size: 18),
                    label: Text(onCut ? 'Bring back' : 'Reset'),
                  ),
                ],
              ),
              _hint(
                parts > 1
                    ? '$parts parts · move the white line to a part, then '
                          'delete it · length ${durationLabel(item.playedMs)}'
                    : 'Move the white line on the timeline, then tap Split',
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _voicePanel() {
    final item = _item;
    if (!_videoReady) return _hint('Loading video…');
    if (_recording) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FilledButton.icon(
            key: const ValueKey('voice-stop'),
            onPressed: () => _stopVoice(),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.like,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.stop_rounded),
            label: Text('Stop  ${durationLabel(_recMs)}'),
          ),
          _hint('Speak now… the video is playing without sound'),
        ],
      );
    }
    if (!item.hasVoice) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FilledButton.icon(
            key: const ValueKey('voice-record'),
            onPressed: _startVoice,
            style: _limeButton,
            icon: const Icon(Icons.mic),
            label: const Text('Record voice'),
          ),
          _hint(
            'Starts at the white line. The video plays while you speak.',
          ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '🎤 Voice over · ${durationLabel(item.voiceDurMs)} · starts at '
            '${durationLabel(item.voiceStartMs)}',
            key: const ValueKey('voice-info'),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              OutlinedButton.icon(
                style: _darkButton,
                onPressed: _startVoice,
                icon: const Icon(Icons.mic, size: 18),
                label: const Text('Record again'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('voice-delete'),
                style: _darkButton,
                onPressed: _deleteVoice,
                icon: const Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: AppColors.like,
                ),
                label: const Text('Delete'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filtersPanel() {
    final item = _item;
    Widget sample(List<double> m) {
      if (!item.isVideo) {
        return applyMatrix(
          m,
          Image.file(item.file, fit: BoxFit.cover, cacheWidth: 160),
        );
      }
      final t = item.thumbs;
      final bytes = t == null
          ? null
          : t.firstWhere((b) => b != null, orElse: () => null) as Uint8List?;
      return applyMatrix(
        m,
        bytes != null
            ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
            : const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFFE8A06A), Color(0xFF3E6FB0)],
                  ),
                ),
              ),
      );
    }

    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      itemCount: kFilterPresets.length,
      separatorBuilder: (context, index) => const SizedBox(width: 10),
      itemBuilder: (context, i) {
        final p = kFilterPresets[i];
        final sel = item.color.preset == i;
        return GestureDetector(
          onTap: () =>
              setState(() => item.color = item.color.copyWith(preset: i)),
          child: Column(
            children: [
              Text(
                p.name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: sel ? FontWeight.w800 : FontWeight.w500,
                  color: sel ? AppColors.lime : AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: 64,
                height: 64,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: sel ? AppColors.lime : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: sample(p.matrix),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  double _adjustValue(ColorEdits c, _Adjust a) => switch (a) {
    _Adjust.brightness => c.brightness,
    _Adjust.contrast => c.contrast,
    _Adjust.saturation => c.saturation,
    _Adjust.warmth => c.warmth,
    _Adjust.fade => c.fade,
  };

  ColorEdits _setAdjust(ColorEdits c, _Adjust a, double v) => switch (a) {
    _Adjust.brightness => c.copyWith(brightness: v),
    _Adjust.contrast => c.copyWith(contrast: v),
    _Adjust.saturation => c.copyWith(saturation: v),
    _Adjust.warmth => c.copyWith(warmth: v),
    _Adjust.fade => c.copyWith(fade: v),
  };

  Widget _adjustPanel() {
    final item = _item;
    final v = _adjustValue(item.color, _adjust);
    final min = _adjust == _Adjust.fade ? 0.0 : -1.0;
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final a in _Adjust.values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _Chip(
                    label: a.label,
                    icon: a.icon,
                    selected: a == _adjust,
                    dot: _adjustValue(item.color, a) != 0,
                    onTap: () => setState(() => _adjust = a),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Row(
            children: [
              SizedBox(
                width: 42,
                child: Text(
                  '${(v * 100).round()}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Expanded(
                child: Slider(
                  value: v.clamp(min, 1.0),
                  min: min,
                  max: 1,
                  activeColor: AppColors.lime,
                  onChanged: (x) => setState(
                    () => item.color = _setAdjust(item.color, _adjust, x),
                  ),
                ),
              ),
              TextButton(
                onPressed: () => setState(
                  () => item.color = ColorEdits(preset: item.color.preset),
                ),
                child: const Text('Reset'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _cropPanel() {
    final item = _item;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final a in aspectsFor(widget.mode))
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _Chip(
                    label: a.label,
                    icon: Icons.crop,
                    selected: item.aspect == a,
                    onTap: () => setState(() {
                      item.aspect = a;
                      item.resetZoom();
                    }),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _RoundAction(
              icon: Icons.rotate_90_degrees_ccw,
              label: 'Rotate',
              onTap: () => setState(() {
                item.turns = (item.turns + 3) % 4;
                item.resetZoom();
              }),
            ),
            _RoundAction(
              icon: Icons.flip,
              label: 'Flip',
              onTap: () => setState(() => item.flip = !item.flip),
            ),
            _RoundAction(
              icon: Icons.center_focus_strong_outlined,
              label: 'Reset',
              onTap: () => setState(() {
                item.turns = 0;
                item.flip = false;
                item.aspect = widget.mode == ComposeMode.story
                    ? CropAspect.story
                    : CropAspect.original;
                item.resetZoom();
              }),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'Pinch to zoom · drag to move',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }

  Widget _textPanel() {
    final item = _item;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: () => _editText(item, null),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.lime,
            foregroundColor: Colors.black,
            textStyle: const TextStyle(
              fontFamily: AppTheme.fontFamily,
              fontWeight: FontWeight.w800,
            ),
          ),
          icon: const Icon(Icons.text_fields),
          label: const Text('Add text'),
        ),
        const SizedBox(height: 10),
        Text(
          item.texts.isEmpty
              ? 'Add words on your photo'
              : 'Drag text to move it · tap it to edit',
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ],
    );
  }

  Widget _trimPanel() {
    final item = _item;
    if (!_videoReady || item.durationMs <= 0) {
      return const Center(
        child: Text(
          'Loading video…',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }
    final max = maxVideoMs(widget.mode);
    final total = item.durationMs.toDouble();
    final start = item.trimStart.toDouble().clamp(0.0, total);
    final end = (item.trimEnd > 0 ? item.trimEnd : item.durationMs)
        .toDouble()
        .clamp(start, total);
    final thumbs = item.thumbs;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            height: 56,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  left: 22,
                  right: 22,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Row(
                      children: [
                        for (var i = 0; i < 8; i++)
                          Expanded(
                            child: thumbs != null && thumbs[i] != null
                                ? Image.memory(
                                    thumbs[i] as Uint8List,
                                    fit: BoxFit.cover,
                                    height: 56,
                                    gaplessPlayback: true,
                                  )
                                : Container(
                                    color: i.isEven
                                        ? const Color(0xFF1D2029)
                                        : const Color(0xFF262B35),
                                  ),
                          ),
                      ],
                    ),
                  ),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 56,
                    activeTrackColor: AppColors.lime.withValues(alpha: 0.18),
                    inactiveTrackColor: Colors.black.withValues(alpha: 0.55),
                    rangeTrackShape: const RectangularRangeSliderTrackShape(),
                    rangeThumbShape: const RoundRangeSliderThumbShape(
                      enabledThumbRadius: 9,
                    ),
                    thumbColor: AppColors.lime,
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: RangeSlider(
                    values: RangeValues(start, end),
                    min: 0,
                    max: total,
                    onChanged: (r) {
                      var s = r.start, e = r.end;
                      final movedStart = (s - start).abs() > (e - end).abs();
                      if (e - s > max) {
                        if (movedStart) {
                          e = s + max;
                        } else {
                          s = e - max;
                        }
                      }
                      if (e - s < 1000) {
                        if (movedStart) {
                          s = (e - 1000).clamp(0, total);
                        } else {
                          e = (s + 1000).clamp(0, total);
                        }
                      }
                      setState(() {
                        item.trimStart = s.round();
                        item.trimEnd = e.round();
                      });
                      _video?.seekTo(
                        Duration(
                          milliseconds: movedStart
                              ? s.round()
                              : (e - 800).round(),
                        ),
                      );
                    },
                    onChangeEnd: (_) {
                      _video?.seekTo(Duration(milliseconds: item.trimStart));
                      _video?.play();
                      _attachVoicePreview();
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                durationLabel(item.trimStart),
                style: const TextStyle(fontSize: 12),
              ),
              const Spacer(),
              Text(
                'Length ${durationLabel(item.trimmedMs)}'
                '  ·  max ${durationLabel(max)}',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.lime,
                ),
              ),
              const Spacer(),
              Text(
                durationLabel(end.round()),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _soundPanel() {
    final item = _item;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SwitchListTile(
          value: !item.muted,
          activeThumbColor: AppColors.lime,
          contentPadding: EdgeInsets.zero,
          secondary: Icon(
            item.muted ? Icons.volume_off : Icons.volume_up,
            color: AppColors.lime,
          ),
          title: const Text(
            'Original sound',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: const Text('Turn off to post the video without sound'),
          onChanged: (on) {
            setState(() => item.muted = !on);
            _video?.setVolume(on ? 1 : 0);
          },
        ),
      ),
    );
  }

  String _toolLabel(_Tool t) => switch (t) {
    _Tool.filters => 'Filters',
    _Tool.adjust => 'Adjust',
    _Tool.crop => 'Crop',
    _Tool.text => 'Text',
    _Tool.trim => 'Trim',
    _Tool.sound => 'Sound',
    _Tool.split => 'Split',
    _Tool.music => 'Music',
    _Tool.voice => 'Voice',
    _Tool.stickers => 'Stickers',
  };

  IconData _toolIcon(_Tool t) => switch (t) {
    _Tool.filters => Icons.auto_awesome,
    _Tool.adjust => Icons.tune,
    _Tool.crop => Icons.crop_rotate,
    _Tool.text => Icons.text_fields,
    _Tool.trim => Icons.content_cut,
    _Tool.sound => Icons.volume_up_outlined,
    _Tool.split => Icons.vertical_split_outlined,
    _Tool.music => Icons.music_note_outlined,
    _Tool.voice => Icons.mic_none,
    _Tool.stickers => Icons.emoji_emotions_outlined,
  };

  // ---------------------------------------------------------------- timeline

  static const double _tlPad = 16;

  /// v0.12: timeline of the trimmed video. Rows: video (removed parts dark,
  /// split lines), music, voice over, one row per text / sticker. The white
  /// line = where you are: tap or drag to move it.
  Widget _timeline() {
    final item = _item;
    final c = _video;
    if (!item.isVideo || c == null || !_videoReady || item.durationMs <= 0) {
      return const SizedBox.shrink();
    }
    final start = item.trimStart, end = item.endMs;
    final len = math.max(1, end - start);
    final cuts = item.activeCuts;
    return LayoutBuilder(
      builder: (context, box) {
        final w = math.max(1.0, box.maxWidth - _tlPad * 2);
        double xOf(int ms) =>
            _tlPad + ((ms - start) / len).clamp(0.0, 1.0) * w;
        int msOf(double x) =>
            (start + ((x - _tlPad) / w).clamp(0.0, 1.0) * len).round();
        int msPerPx(double dx) => (dx / w * len).round();

        void seek(double x) {
          final ms = msOf(x);
          c.seekTo(Duration(milliseconds: ms));
        }

        Widget bar({
          required Key key,
          required int s,
          required int e,
          required Color color,
          required String label,
          bool selected = false,
          VoidCallback? onTap,
          GestureDragUpdateCallback? onMove,
          GestureDragUpdateCallback? onStart,
          GestureDragUpdateCallback? onEnd,
        }) {
          final left = xOf(s), right = xOf(e);
          final width = math.max(16.0, right - left);
          return Positioned(
            key: key,
            left: left,
            width: width,
            top: 1,
            bottom: 1,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              onHorizontalDragUpdate: onMove,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: selected ? 0.55 : 0.3),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: selected ? Colors.white : color,
                          width: selected ? 1.5 : 1,
                        ),
                      ),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        textScaler: TextScaler.noScaling,
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  if (onStart != null)
                    Positioned(
                      left: -8,
                      top: -2,
                      bottom: -2,
                      width: 18,
                      child: GestureDetector(
                        key: ValueKey('${(key as ValueKey).value}-start'),
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: onStart,
                        child: const _Handle(),
                      ),
                    ),
                  if (onEnd != null)
                    Positioned(
                      right: -8,
                      top: -2,
                      bottom: -2,
                      width: 18,
                      child: GestureDetector(
                        key: ValueKey('${(key as ValueKey).value}-end'),
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: onEnd,
                        child: const _Handle(),
                      ),
                    ),
                ],
              ),
            ),
          );
        }

        Widget row(double h, List<Widget> children) => SizedBox(
          height: h,
          width: box.maxWidth,
          child: Stack(clipBehavior: Clip.none, children: children),
        );

        // ---- video row
        final thumbs = item.thumbs;
        const slots = 10;
        final videoRow = row(40, [
          Positioned(
            left: _tlPad,
            width: w,
            top: 0,
            bottom: 0,
            child: Row(
              children: [
                for (var k = 0; k < slots; k++)
                  Expanded(
                    child: Builder(
                      builder: (_) {
                        final t = start + (k + 0.5) * len / slots;
                        final idx = thumbs == null
                            ? -1
                            : (t / item.durationMs * thumbs.length)
                                  .floor()
                                  .clamp(0, thumbs.length - 1);
                        final b = idx >= 0 ? thumbs![idx] : null;
                        return b != null
                            ? Image.memory(
                                b as Uint8List,
                                fit: BoxFit.cover,
                                height: 40,
                                gaplessPlayback: true,
                              )
                            : Container(
                                color: k.isEven
                                    ? const Color(0xFF1D2029)
                                    : const Color(0xFF262B35),
                              );
                      },
                    ),
                  ),
              ],
            ),
          ),
          for (final cut in cuts)
            Positioned(
              key: ValueKey('tl-cut-${cut.startMs}'),
              left: xOf(cut.startMs),
              width: math.max(2.0, xOf(cut.endMs) - xOf(cut.startMs)),
              top: 0,
              bottom: 0,
              child: Container(
                color: Colors.black.withValues(alpha: 0.75),
                alignment: Alignment.center,
                child: xOf(cut.endMs) - xOf(cut.startMs) > 18
                    ? const Icon(Icons.close, size: 14, color: AppColors.like)
                    : null,
              ),
            ),
          for (final sp in item.splits)
            if (sp > start && sp < end)
              Positioned(
                key: ValueKey('tl-split-$sp'),
                left: xOf(sp) - 1,
                width: 2,
                top: -3,
                bottom: -3,
                child: const ColoredBox(color: AppColors.lime),
              ),
        ]);

        final rows = <Widget>[
          // time
          SizedBox(
            height: 16,
            child: ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: c,
              builder: (context, v, _) {
                final played = VideoTime.playedAt(
                  v.position.inMilliseconds,
                  start,
                  cuts,
                );
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _tlPad),
                  child: Row(
                    children: [
                      Text(
                        '${durationLabel(played)} / '
                        '${durationLabel(item.playedMs)}',
                        key: const ValueKey('tl-time'),
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      if (item.segments.length > 1)
                        Text(
                          '${item.segments.length} parts',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          videoRow,
          if (_audio != null && _musicAllowed)
            row(20, [
              bar(
                key: const ValueKey('tl-music'),
                s: start,
                e: end,
                color: AppColors.lime,
                label: '♪ ${_audio!.name}',
                onTap: () => setState(() => _tool = _Tool.music),
              ),
            ]),
          if (item.hasVoice)
            row(20, [
              bar(
                key: const ValueKey('tl-voice'),
                s: VideoTime.sourceAt(item.voiceStartMs, start, cuts),
                e: VideoTime.sourceAt(
                  item.voiceStartMs + item.voiceDurMs,
                  start,
                  cuts,
                ),
                color: const Color(0xFF4DA3FF),
                label: '🎤 Voice ${durationLabel(item.voiceDurMs)}',
                onTap: () => setState(() => _tool = _Tool.voice),
              ),
            ]),
          for (var i = 0; i < item.overlays.length; i++)
            row(22, [
              () {
                final o = item.overlays[i];
                final s0 = math.max(o.startMs, start);
                final e0 = o.endMs > 0 ? math.min(o.endMs, end) : end;
                final sel = _selOverlay == i;
                void setTimes(int s, int e) {
                  final ns = s <= start + 40 ? 0 : s;
                  final ne = e >= end - 40 ? 0 : e;
                  setState(
                    () => item.overlays[i] = item.overlays[i].copyWith(
                      startMs: ns,
                      endMs: ne,
                    ),
                  );
                }

                return bar(
                  key: ValueKey('tl-ov-$i'),
                  s: s0,
                  e: e0,
                  color: o.isSticker
                      ? const Color(0xFFFFC53D)
                      : const Color(0xFFB97CFF),
                  label: o.isSticker ? o.text : 'T  ${o.text}',
                  selected: sel,
                  onTap: () => setState(() {
                    _selOverlay = i;
                    _tool = o.isSticker ? _Tool.stickers : _Tool.text;
                  }),
                  onMove: sel
                      ? (d) {
                          final dm = msPerPx(d.delta.dx);
                          final l = e0 - s0;
                          final ns = (s0 + dm).clamp(start, end - l);
                          setTimes(ns, ns + l);
                        }
                      : null,
                  onStart: sel
                      ? (d) => setTimes(
                          (s0 + msPerPx(d.delta.dx)).clamp(start, e0 - 300),
                          e0,
                        )
                      : null,
                  onEnd: sel
                      ? (d) => setTimes(
                          s0,
                          (e0 + msPerPx(d.delta.dx)).clamp(s0 + 300, end),
                        )
                      : null,
                );
              }(),
            ]),
        ];

        final content = Stack(
          children: [
            Column(mainAxisSize: MainAxisSize.min, children: rows),
            // the white line
            Positioned.fill(
              child: IgnorePointer(
                child: ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: c,
                  builder: (context, v, _) {
                    final x = xOf(v.position.inMilliseconds);
                    return Stack(
                      children: [
                        Positioned(
                          key: const ValueKey('tl-playhead'),
                          left: x - 1,
                          top: 14,
                          bottom: 0,
                          width: 2,
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              boxShadow: [
                                BoxShadow(color: Colors.black54, blurRadius: 3),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        );

        return GestureDetector(
          key: const ValueKey('editor-timeline'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => seek(d.localPosition.dx),
          onHorizontalDragStart: (d) {
            _scrubWasPlaying = c.value.isPlaying;
            if (_scrubWasPlaying && !_recording) c.pause();
            seek(d.localPosition.dx);
          },
          onHorizontalDragUpdate: (d) => seek(d.localPosition.dx),
          onHorizontalDragEnd: (_) {
            if (_scrubWasPlaying && !_recording) c.play();
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 150),
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.only(top: 4, bottom: 6),
              child: content,
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final title = switch (widget.mode) {
      ComposeMode.photo => 'Edit post',
      ComposeMode.clip => 'Edit clip',
      ComposeMode.story => 'Edit moment',
    };
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // top bar
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.close),
                      ),
                      Expanded(
                        child: Text(
                          _items.length > 1
                              ? '$title  ${_index + 1}/${_items.length}'
                              : title,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      FilledButton(
                        key: const ValueKey('editor-next'),
                        onPressed: _exporting ? null : _next,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.lime,
                          foregroundColor: Colors.black,
                          visualDensity: VisualDensity.compact,
                          textStyle: const TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        child: const Text('Next'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: item.isVideo ? _videoCanvas(item) : _photoCanvas(item),
                ),
                if (_items.length > 1) _strip(),
                if (item.isVideo) _timeline(),
                SizedBox(height: 124, child: _panel()),
                // tool tabs (v0.12: scroll sideways, music is a tool)
                Container(
                  height: 56,
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: AppColors.border)),
                  ),
                  child: ListView(
                    key: const ValueKey('editor-tools'),
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    children: [
                      for (final t in _tools)
                        SizedBox(
                          width: _tools.length <= 5
                              ? (MediaQuery.of(context).size.width - 12) /
                                    _tools.length
                              : 66,
                          child: InkWell(
                            key: ValueKey('tool-${t.name}'),
                            onTap: () => setState(() => _tool = t),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _toolIcon(t),
                                  size: 21,
                                  color: _tool == t
                                      ? AppColors.lime
                                      : AppColors.textSecondary,
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  _toolLabel(t),
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: _tool == t
                                        ? FontWeight.w800
                                        : FontWeight.w500,
                                    color: _tool == t
                                        ? AppColors.lime
                                        : AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (_exporting)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0xAA000000),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('Preparing…'),
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

  Widget _strip() {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: _items.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final it = _items[i];
          final sel = i == _index;
          return GestureDetector(
            onTap: () => _select(i),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: sel ? AppColors.lime : AppColors.border,
                      width: sel ? 2 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: it.isVideo
                      ? const ColoredBox(
                          color: AppColors.surface,
                          child: Icon(Icons.videocam, size: 22),
                        )
                      : Image.file(it.file, fit: BoxFit.cover, cacheWidth: 120),
                ),
                if (_items.length > 1)
                  Positioned(
                    right: -6,
                    top: -6,
                    child: GestureDetector(
                      onTap: () => _remove(i),
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: const BoxDecoration(
                          color: Colors.black,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close, size: 14),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------- helpers

/// Drag handle at the ends of a timeline bar.
class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 8,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(3),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 3)],
        ),
      ),
    );
  }
}

class _Raw {
  const _Raw(this.data, this.width, this.height);
  final Uint8List data;
  final int width;
  final int height;
}

Uint8List _encodeJpg(_Raw r) {
  final im = img.Image.fromBytes(
    width: r.width,
    height: r.height,
    bytes: r.data.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return img.encodeJpg(im, quality: 90);
}

/// Rule-of-thirds lines.
class _Grid extends CustomPainter {
  const _Grid();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.45)
      ..strokeWidth = 0.8;
    for (var i = 1; i < 3; i++) {
      final x = size.width * i / 3, y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white.withValues(alpha: 0.7)
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(covariant _Grid oldDelegate) => false;
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.dot = false,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool dot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.lime : AppColors.surface,
      shape: StadiumBorder(
        side: BorderSide(color: selected ? AppColors.lime : AppColors.border),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? Colors.black : AppColors.lime,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.black : AppColors.textPrimary,
                ),
              ),
              if (dot) ...[
                const SizedBox(width: 5),
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: selected ? Colors.black : AppColors.lime,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.border),
              ),
              child: Icon(icon, size: 21),
            ),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 11.5)),
          ],
        ),
      ),
    );
  }
}

class _TextResult {
  const _TextResult({
    this.text = '',
    this.color = Colors.white,
    this.size = 0.08,
    this.background = false,
    this.delete = false,
  });
  final String text;
  final Color color;
  final double size;
  final bool background;
  final bool delete;
}

const List<Color> _textColors = [
  Colors.white,
  Colors.black,
  AppColors.lime,
  Color(0xFF62F0A4),
  Color(0xFFFF4D67),
  Color(0xFFFFC53D),
  Color(0xFF4DA3FF),
  Color(0xFFB97CFF),
];

class _TextSheet extends StatefulWidget {
  const _TextSheet({this.initial});

  /// null = new text.
  final _TextResult? initial;

  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  late final _ctrl = TextEditingController(text: widget.initial?.text ?? '');
  late Color _color = widget.initial?.color ?? Colors.white;
  late double _size = widget.initial?.size ?? 0.08;
  late bool _bg = widget.initial?.background ?? false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            maxLines: 3,
            minLines: 1,
            maxLength: 120,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: _color == Colors.black ? Colors.white : _color,
            ),
            decoration: const InputDecoration(
              hintText: 'Type something…',
              border: InputBorder.none,
            ),
          ),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final c in _textColors)
                  GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 30,
                      height: 30,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _color == c ? AppColors.lime : Colors.white24,
                          width: _color == c ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Row(
            children: [
              const Icon(Icons.format_size, size: 20),
              Expanded(
                child: Slider(
                  value: _size,
                  min: 0.04,
                  max: 0.18,
                  activeColor: AppColors.lime,
                  onChanged: (v) => setState(() => _size = v),
                ),
              ),
              IconButton(
                tooltip: 'Background',
                onPressed: () => setState(() => _bg = !_bg),
                icon: Icon(
                  _bg ? Icons.format_color_fill : Icons.format_color_reset,
                  color: _bg ? AppColors.lime : null,
                ),
              ),
            ],
          ),
          Row(
            children: [
              if (widget.initial != null)
                TextButton.icon(
                  onPressed: () =>
                      Navigator.pop(context, const _TextResult(delete: true)),
                  icon: const Icon(Icons.delete_outline, color: AppColors.like),
                  label: const Text(
                    'Delete',
                    style: TextStyle(color: AppColors.like),
                  ),
                ),
              const Spacer(),
              FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  _TextResult(
                    text: _ctrl.text,
                    color: _color,
                    size: _size,
                    background: _bg,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.lime,
                  foregroundColor: Colors.black,
                  textStyle: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                child: const Text('Done'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
