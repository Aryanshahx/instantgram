import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';

import '../../core/services/media_service.dart';
import '../../core/services/music_player.dart';
import '../../core/services/gesture_exclusion.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/time_ago.dart';
import '../../shared/widgets/face_effects.dart';
import '../../shared/widgets/media_links.dart';
import '../../shared/widgets/smooth_clock.dart';
import '../../shared/models/post.dart';
import '../../shared/widgets/video_extras.dart';
import '../../shared/widgets/stickers.dart';
import '../music/presentation/music_picker_sheet.dart';
import '../post/presentation/create_post_screen.dart';
import 'edit_models.dart';
import 'filters.dart';
import 'photo_render.dart';
import 'video_frames.dart';
import '../../shared/widgets/bio_font.dart';
import '../../shared/widgets/hi_text_check.dart';

/// Opens the editor for picked media, then the share screen.
Future<void> openEditor(
  BuildContext context,
  List<PickedMedia> media,
  ComposeMode mode, {
  PickedAudio? audio,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          MediaEditorScreen(media: media, mode: mode, initialAudio: audio),
    ),
  );
}

// v0.12: + split, music (was at the top), voice over, stickers
enum _Tool {
  // v0.13: trim + split are on the timeline (always visible for videos)
  music,
  voice,
  text,
  stickers,
  // v0.0.2: link sticker (tap = open the website)
  link,
  filters,
  adjust,
  crop,
  sound,
}

/// v0.12: emoji stickers.
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
    this.initialAudio,
  });

  final List<PickedMedia> media;
  final ComposeMode mode;

  /// Music update: "Use this audio" -> starts with this song.
  final PickedAudio? initialAudio;

  /// Tests: called with the result instead of opening the share screen.
  final ValueChanged<List<EditedMedia>>? onDone;

  @override
  State<MediaEditorScreen> createState() => _MediaEditorScreenState();
}

class _MediaEditorScreenState extends State<MediaEditorScreen>
    with SingleTickerProviderStateMixin {
  late final List<EditItem> _items = widget.media
      .map((m) => EditItem(m, mode: widget.mode))
      .toList();
  int _index = 0;
  late _Tool _tool = widget.initialAudio != null
      ? _Tool.music
      : _items.first.isVideo
      ? _Tool.text
      : _Tool.filters;
  _Adjust _adjust = _Adjust.brightness;
  bool _exporting = false;
  bool _showGrid = false;

  VideoPlayerController? _video;
  bool _videoReady = false;
  String? _videoError;

  /// Music from phone storage (v0.16: posts, clips and moments).
  late PickedAudio? _audio = widget.initialAudio;
  bool _audioPlaying = false;
  bool get _musicAllowed => true;

  /// Voice over: posts and clips only (not moments).
  bool get _voiceAllowed => widget.mode != ComposeMode.story;

  // v0.12: selected text / sticker on a video, voice over
  int? _selOverlay;
  DateTime _lastSkip = DateTime.fromMillisecondsSinceEpoch(0);
  VoiceTrack? _voiceTrack;
  AudioRecorder? _rec;
  bool _recording = false;
  int _recStartPlayed = 0;
  DateTime? _recAt;
  Timer? _recTimer;
  int _recMs = 0;
  bool _musicBeforeRec = false;

  // v0.14 timeline: the white line stays in the middle, slide = move in
  // time, pinch = zoom, tap a part = select it (its own trim handles)
  final ScrollController _tlScroll = ScrollController();
  final GlobalKey _tlKey = GlobalKey();
  late final Ticker _tlTicker = createTicker(_onTlTick);
  double _tlZoom = 1;
  double _tlBasePx = 0; // px per ms when the whole video fits
  double _tlPx = 0; // px per ms now (with zoom)
  int? _selSeg;
  bool _tlUser = false;
  bool _tlWasPlaying = false;
  DateTime _tlSeekAt = DateTime(2000);
  DateTime _tlHoldUntil = DateTime(2000);
  // v0.0.1: smooth white line while playing (no shaking)
  final SmoothClock _tlClock = SmoothClock();

  // v0.0.1: pinch ANYWHERE to resize the text / sticker your first
  // finger is on (it was hard to get both fingers on a small text)
  final Map<int, Offset> _cvPtrs = {};
  double? _cvPinchDist;
  double _cvPinchBase = 0;
  TextLayer? _cvText;
  int? _cvOverlay;
  TextLayer? _selText;
  double _handleBase = 0;
  final Map<int, Offset> _tlPtrs = {};
  bool _pinching = false;
  double _pinchDist = 1;
  double _pinchZoom = 1;
  int _pinchAnchor = 0;
  int _edgeBase = 0;
  double _edgeDx = 0;

  EditItem get _item => _items[_index];

  List<_Tool> get _tools => _item.isVideo
      ? [
          if (_musicAllowed) _Tool.music,
          if (_voiceAllowed) _Tool.voice,
          _Tool.text,
          _Tool.stickers,
          if (_linksAllowed) _Tool.link,
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
          if (_linksAllowed) _Tool.link,
          if (_musicAllowed) _Tool.music,
        ];

  /// v0.0.2: links on posts and clips (not moments / comment photos).
  bool get _linksAllowed =>
      widget.mode != ComposeMode.story && widget.onDone == null;

  @override
  void initState() {
    super.initState();
    // music update: "Use this audio" -> the song plays at once
    final a = widget.initialAudio;
    if (a != null) {
      _audioPlaying = true;
      MusicPlayer.instance.play(_kPreview, a.source, startMs: a.startMs);
    }
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
    _tlTicker.dispose();
    _tlScroll.dispose();
    GestureExclusion.instance.clear();
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
    _selSeg = null;
    _tlZoom = 1;
    if (_tlTicker.isActive) _tlTicker.stop();
    GestureExclusion.instance.clear();
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
      if (!_tlTicker.isActive) _tlTicker.start();
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
      if (keep) {
        _snack('Too short. Tap record and speak while the video plays.');
      }
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
    unawaited(File(path).delete().then((_) {}, onError: (Object _) {}));
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

  /// v0.14: split at the white line (the middle of the timeline).
  void _splitHere() {
    final item = _item;
    final p = _tlMs;
    final why = item.splitAt(p);
    if (why != null) {
      _snack(why);
      return;
    }
    HapticFeedback.selectionClick();
    // the new part on the right is selected (its own trim handles)
    setState(() => _selSeg = item.segmentIndexAt(p));
  }

  void _deletePart() {
    final item = _item;
    final segs = item.segments;
    final seg = _targetPart(segs, _selSeg);
    if (seg == null || segs.length < 2) {
      _snack('Split the video first, then delete a part.');
      return;
    }
    if (item.keptOf(seg) == null) return;
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
    final seg = _targetPart(item.segments, _selSeg);
    setState(() {
      if (seg != null && item.keptOf(seg) == null) {
        item.restorePart(seg);
      } else {
        item.cuts = [];
        item.splits.clear();
        _selSeg = null;
      }
    });
    _attachVoicePreview();
  }

  Future<void> _makeThumbs(EditItem item) async {
    if (item.thumbs != null || item.durationMs <= 0) return;
    const n = 12;
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

  /// Music update: library / AI song / phone.
  Future<void> _pickMusic() async {
    final wasOn = _audioPlaying;
    if (wasOn) _playMusic(false);
    final a = await showMusicPicker(context);
    if (!mounted) return;
    if (a == null) {
      if (wasOn) _playMusic(true);
      return;
    }
    setState(() => _audio = a);
    _playMusic(true);
  }

  /// Start point dragged (shown at once, played on release).
  int? _dragStartMs;

  void _setMusicStart(int ms) {
    final a = _audio;
    if (a == null) return;
    setState(() {
      _dragStartMs = null;
      _audio = a.withStart(ms);
    });
    _playMusic(true);
  }

  void _playMusic(bool on) {
    final a = _audio;
    if (a == null) return;
    setState(() => _audioPlaying = on);
    if (on) {
      MusicPlayer.instance.play(_kPreview, a.source, startMs: a.startMs);
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
            'Library · AI songs · your phone · plays in a loop',
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
          // music update: which part of the song plays
          ValueListenableBuilder<int>(
            valueListenable: MusicPlayer.instance.length,
            builder: (_, playing, _) {
              final len = a.durationMs > 0
                  ? a.durationMs
                  : MusicPlayer.instance.isOwner(_kPreview)
                  ? playing
                  : 0;
              return MusicStartSlider(
                startMs: _dragStartMs ?? a.startMs,
                lengthMs: len,
                onChanged: (ms) => setState(() => _dragStartMs = ms),
                onChangeEnd: _setMusicStart,
              );
            },
          ),
          TextButton.icon(
            key: const ValueKey('editor-music-change'),
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
    // v0.17: stop the video + music first (nothing plays behind the
    // share screen), go on again when coming back
    final c = _video;
    final wasPlaying = c != null && c.value.isPlaying;
    final musicWasOn = _audioPlaying;
    if (wasPlaying) await c.pause();
    if (musicWasOn) _playMusic(false);
    if (!mounted) return;
    setState(() => _exporting = true);
    var resume = true;
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
              links: List.unmodifiable(item.links),
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
              links: List.unmodifiable(item.links),
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
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                CreatePostScreen(items: out, mode: widget.mode, audio: _audio),
          ),
        );
      }
      // the editor closes (moment / reply) -> stays stopped
      resume = widget.onDone == null;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not prepare media: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
        if (resume) {
          if (musicWasOn && _audio != null) _playMusic(true);
          if (wasPlaying && _video == c && c.value.isInitialized) {
            unawaited(c.play());
          }
        }
      }
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
    // v0.13: sticker pictures
    final stickers = <String, ui.Image>{};
    for (final t in item.texts) {
      if (t.sticker &&
          StickerPack.isPack(t.text) &&
          !stickers.containsKey(t.text)) {
        final img = await StickerPack.load(t.text);
        if (img != null) stickers[t.text] = img;
      }
    }
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
          stickers: stickers,
        ),
        outWidth: targetW,
      );
    } finally {
      src.dispose();
      for (final s in stickers.values) {
        s.dispose();
      }
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
      links: List.unmodifiable(item.links),
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
            child: _pinchArea(
              Stack(
              children: [
                RepaintBoundary(
                  child: ClipRect(
                    child: ColoredBox(
                      color: Colors.black,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Positioned.fill(
                            child: InteractiveViewer(
                              transformationController: item.zoom,
                              // v0.0.1: no photo zoom while resizing a text
                              scaleEnabled: !_cvResizing && _cvText == null,
                              panEnabled: !_cvResizing && _cvText == null,
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
                          _linksOnCanvas(item),
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
        fontFamily: t.sticker
            ? AppTheme.fontFamily
            : BioFont.family(t.font, AppTheme.fontFamily),
        color: t.color,
        fontSize: t.sticker ? fs : fs * BioFont.factor(t.font),
        fontWeight: FontWeight.w800,
        height: 1.15,
        shadows: t.background || t.sticker
            ? null
            : [Shadow(blurRadius: fs * 0.12, color: Colors.black54)],
      ),
    );
    final picture = t.sticker && StickerPack.isPack(t.text);
    final limits = _sizeLimits(t.text, t.sticker);
    final sel = identical(_selText, t);
    final body = Listener(
      // first finger on it: pinch anywhere resizes it
      onPointerDown: (_) {
        if (_cvPtrs.isEmpty) {
          _cvText = t;
          if (!sel) setState(() => _selText = t);
        }
      },
      child: GestureDetector(
        onScaleUpdate: (d) => setState(() {
          t.pos = Offset(
            (t.pos.dx + d.focalPointDelta.dx / fw).clamp(0.0, 1.0),
            (t.pos.dy + d.focalPointDelta.dy / fh).clamp(0.0, 1.0),
          );
        }),
        onTap: () => t.sticker ? _removeSticker(item, t) : _editText(item, t),
        child: Container(
          padding: const EdgeInsets.all(11),
          decoration: sel
              ? BoxDecoration(
                  border: Border.all(color: Colors.white70, width: 1),
                  borderRadius: BorderRadius.circular(6),
                )
              : null,
          child: picture
              ? StickerImage(text: t.text, width: t.size * fw)
              : ConstrainedBox(
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
    return Positioned(
      left: t.pos.dx * fw,
      top: t.pos.dy * fh,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: Stack(
          children: [
            body,
            if (sel)
              Positioned(
                right: 0,
                bottom: 0,
                child: _resizeHandle(
                  key: const ValueKey('text-resize'),
                  onStart: () => _handleBase = t.size,
                  onDrag: (dx) => setState(() {
                    _handleBase += dx / fw * (picture ? 1.0 : 0.35);
                    t.size = _handleBase.clamp(limits.$1, limits.$2);
                  }),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// v0.0.1: drag the corner to make a text / sticker bigger or smaller.
  Widget _resizeHandle({
    required Key key,
    required VoidCallback onStart,
    required ValueChanged<double> onDrag,
  }) {
    return GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => onStart(),
      onPanUpdate: (d) => onDrag((d.delta.dx + d.delta.dy) / 2),
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black45)],
        ),
        child: const Icon(
          Icons.open_in_full_rounded,
          size: 13,
          color: Colors.black,
        ),
      ),
    );
  }

  // ---- pinch anywhere on the picture = size of the touched text / sticker
  double _cvSpan() {
    final p = _cvPtrs.values.take(2).toList();
    if (p.length < 2) return 1;
    return math.max(12.0, (p[0] - p[1]).distance);
  }

  void _cvDown(PointerDownEvent e) {
    if (_cvPtrs.isEmpty && _cvText == null && _cvOverlay == null) {
      // first finger on the empty picture: nothing selected
      if (_selText != null) setState(() => _selText = null);
    }
    _cvPtrs[e.pointer] = e.position;
    if (_cvPtrs.length == 2) {
      final item = _item;
      final t = _cvText;
      final o = _cvOverlay;
      if (t != null) {
        _cvPinchBase = t.size;
      } else if (o != null && o < item.overlays.length) {
        _cvPinchBase = item.overlays[o].size;
      } else {
        return;
      }
      _cvPinchDist = _cvSpan();
      setState(() {}); // the photo zoom stops while you resize
    }
  }

  void _cvMove(PointerMoveEvent e) {
    if (!_cvPtrs.containsKey(e.pointer)) return;
    _cvPtrs[e.pointer] = e.position;
    final d0 = _cvPinchDist;
    if (d0 == null || _cvPtrs.length < 2) return;
    final k = _cvSpan() / d0;
    final item = _item;
    final t = _cvText;
    final o = _cvOverlay;
    setState(() {
      if (t != null) {
        final l = _sizeLimits(t.text, t.sticker);
        t.size = (_cvPinchBase * k).clamp(l.$1, l.$2);
      } else if (o != null && o < item.overlays.length) {
        final ov = item.overlays[o];
        final l = _sizeLimits(ov.text, ov.isSticker);
        item.overlays[o] = ov.copyWith(
          size: (_cvPinchBase * k).clamp(l.$1, l.$2),
        );
      }
    });
  }

  void _cvUp(PointerEvent e) {
    _cvPtrs.remove(e.pointer);
    if (_cvPtrs.length < 2) _cvPinchDist = null;
    if (_cvPtrs.isEmpty) {
      final was = _cvText != null || _cvOverlay != null;
      _cvText = null;
      _cvOverlay = null;
      if (was) setState(() {});
    }
  }

  bool get _cvResizing => _cvPinchDist != null;

  Widget _pinchArea(Widget child) => Listener(
    key: const ValueKey('editor-pinch-area'),
    behavior: HitTestBehavior.translucent,
    onPointerDown: _cvDown,
    onPointerMove: _cvMove,
    onPointerUp: _cvUp,
    onPointerCancel: _cvUp,
    child: child,
  );

  Future<void> _removeSticker(EditItem item, TextLayer t) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (c) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.delete_outline, color: AppColors.like),
          title: const Text('Remove sticker'),
          onTap: () => Navigator.pop(c, true),
        ),
      ),
    );
    if (ok == true && mounted) setState(() => item.texts.remove(t));
  }

  /// v0.13: built-in sticker pack ([id] from [StickerPack.ids]).
  void _addSticker(String id) {
    final item = _item;
    final text = StickerPack.textFor(id);
    HapticFeedback.selectionClick();
    setState(() {
      if (item.isVideo) {
        item.overlays.add(
          VideoOverlay(
            kind: VideoOverlay.stickerKind,
            text: text,
            size: StickerPack.defaultSize,
            x: 0.5,
            y: 0.42,
          ),
        );
        _selOverlay = item.overlays.length - 1;
      } else {
        item.texts.add(
          TextLayer(
            text: text,
            size: StickerPack.defaultSize,
            pos: const Offset(0.5, 0.42),
            sticker: true,
          ),
        );
      }
    });
  }

  /// Size limits while pinching (pack stickers are pictures: bigger).
  static (double, double) _sizeLimits(String text, bool sticker) =>
      sticker && StickerPack.isPack(text)
      ? (StickerPack.minSize, StickerPack.maxSize)
      : (0.03, 0.5);

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
                font: o.font,
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
        font: res.font,
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
                font: layer.font,
              ),
      ),
    );
    if (res == null || !mounted) return;
    // v0.19 Hyper Intelligence: no strong abuse in texts on the picture
    if (!res.delete && !await hiTextOk(context, [res.text])) return;
    if (!mounted) return;
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
            font: res.font,
          ),
        );
      } else {
        layer
          ..text = res.text.trim()
          ..color = res.color
          ..size = res.size
          ..background = res.background
          ..font = res.font;
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
            child: _pinchArea(
              ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  applyMatrix(
                    item.color.isNone ? null : item.color.matrix,
                    VideoPlayer(c),
                  ),
                  // v0.0.1 effects: face effect from the camera
                  if (item.src.face case final fx?)
                    FaceFxLayer(fx: fx, controller: c),
                  _overlaysOnCanvas(item, c),
                  _linksOnCanvas(item),
                  // v0.15: play / pause is next to the timeline (not here)
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
                        child: Stack(
                          children: [
                            Listener(
                              // first finger on it: pinch anywhere = size
                              onPointerDown: (_) {
                                if (_cvPtrs.isEmpty) _cvOverlay = i;
                              },
                              child: GestureDetector(
                                onTap: () {
                                  final o = item.overlays[i];
                                  if (_selOverlay == i && !o.isSticker) {
                                    _editOverlay(i);
                                  } else {
                                    setState(() => _selOverlay = i);
                                  }
                                },
                                onScaleStart: (_) =>
                                    setState(() => _selOverlay = i),
                                onScaleUpdate: (d) => setState(() {
                                  final o = item.overlays[i];
                                  item.overlays[i] = o.copyWith(
                                    x: (o.x + d.focalPointDelta.dx / fw).clamp(
                                      0,
                                      1,
                                    ),
                                    y: (o.y + d.focalPointDelta.dy / fh).clamp(
                                      0,
                                      1,
                                    ),
                                  );
                                }),
                                child: Container(
                                  padding: const EdgeInsets.all(11),
                                  decoration: _selOverlay == i
                                      ? BoxDecoration(
                                          border: Border.all(
                                            color: Colors.white70,
                                            width: 1,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        )
                                      : null,
                                  child: OverlayView(
                                    overlay: item.overlays[i],
                                    frameWidth: fw,
                                  ),
                                ),
                              ),
                            ),
                            if (_selOverlay == i)
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: _resizeHandle(
                                  key: ValueKey('ov-resize-$i'),
                                  onStart: () =>
                                      _handleBase = item.overlays[i].size,
                                  onDrag: (dx) => setState(() {
                                    final o = item.overlays[i];
                                    final l = _sizeLimits(o.text, o.isSticker);
                                    final pic =
                                        o.isSticker &&
                                        StickerPack.isPack(o.text);
                                    _handleBase += dx / fw * (pic ? 1.0 : 0.35);
                                    item.overlays[i] = o.copyWith(
                                      size: _handleBase.clamp(l.$1, l.$2),
                                    );
                                  }),
                                ),
                              ),
                          ],
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
      case _Tool.sound:
        return _soundPanel();
      case _Tool.music:
        return _musicPanel();
      case _Tool.voice:
        return _voicePanel();
      case _Tool.stickers:
        return _stickersPanel();
      case _Tool.link:
        return _linkPanel();
    }
  }

  // ---------------------------------------------------------------- links

  /// v0.0.2: add / edit / remove a link sticker.
  Future<void> _editLink(EditItem item, int? i) async {
    final res = await showMediaLinkEditor(
      context,
      link: i == null ? null : item.links[i],
    );
    if (res == null || !mounted) return;
    setState(() {
      if (res.delete) {
        if (i != null) item.links.removeAt(i);
        return;
      }
      final l = res.link;
      if (l == null) return;
      if (i == null) {
        if (item.links.length < MediaLink.max) {
          // new links go a bit lower each time (not on top of each other)
          item.links.add(l.copyWith(x: 0.5, y: 0.62 + item.links.length * 0.1));
        }
      } else {
        item.links[i] = l;
      }
    });
  }

  Widget _linkPanel() {
    final item = _item;
    final full = item.links.length >= MediaLink.max;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FilledButton.icon(
          key: const ValueKey('editor-add-link'),
          onPressed: full ? null : () => _editLink(item, null),
          style: _limeButton,
          icon: const Icon(Icons.link_rounded),
          label: const Text('Add link'),
        ),
        const SizedBox(height: 6),
        _hint(
          full
              ? 'Max ${MediaLink.max} links · tap one to edit or remove'
              : 'People tap it to open the website · drag to move · tap '
                    'to edit',
        ),
      ],
    );
  }

  /// Link stickers on the photo / video: drag = move, tap = edit.
  Widget _linksOnCanvas(EditItem item) {
    // ALWAYS a Positioned: a plain child would make the photo's Stack
    // shrink to 0 x 0 (= black editor)
    if (item.links.isEmpty) {
      return const Positioned.fill(child: SizedBox.shrink());
    }
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, box) {
          final fw = box.maxWidth, fh = box.maxHeight;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 0; i < item.links.length; i++)
                OverlayPlace(
                  key: ValueKey('editor-link-$i'),
                  x: item.links[i].x,
                  y: item.links[i].y,
                  width: fw,
                  height: fh,
                  child: GestureDetector(
                    onTap: () => _editLink(item, i),
                    onPanUpdate: (d) => setState(() {
                      final l = item.links[i];
                      item.links[i] = l.copyWith(
                        x: (l.x + d.delta.dx / fw).clamp(0.05, 0.95),
                        y: (l.y + d.delta.dy / fh).clamp(0.04, 0.96),
                      );
                    }),
                    child: MediaLinkChip(link: item.links[i], frameWidth: fw),
                  ),
                ),
            ],
          );
        },
      ),
    );
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
          icon: const Icon(
            Icons.delete_outline,
            size: 16,
            color: AppColors.like,
          ),
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
    final hasSel =
        sel != null &&
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

  /// v0.15: big sticker sheet (search + 4 big stickers per row).
  Future<void> _openStickerSheet() async {
    final id = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      builder: (ctx) => const StickerSheet(),
    );
    if (id != null && mounted) _addSticker(id);
  }

  Widget _stickersPanel() {
    final sel = _selOverlay;
    final stickerSel =
        _item.isVideo &&
        sel != null &&
        sel < _item.overlays.length &&
        _item.overlays[sel].isSticker;
    return Column(
      children: [
        Expanded(
          child: Center(
            child: FilledButton.icon(
              key: const ValueKey('sticker-open'),
              style: _limeButton,
              onPressed: _openStickerSheet,
              icon: const Icon(Icons.emoji_emotions_outlined),
              label: const Text('Add a sticker'),
            ),
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
          _hint('Starts at the white line. The video plays while you speak.'),
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
    _Tool.sound => 'Sound',
    _Tool.music => 'Music',
    _Tool.voice => 'Voice',
    _Tool.stickers => 'Stickers',
    _Tool.link => 'Link',
  };

  IconData _toolIcon(_Tool t) => switch (t) {
    _Tool.filters => Icons.auto_awesome,
    _Tool.adjust => Icons.tune,
    _Tool.crop => Icons.crop_rotate,
    _Tool.text => Icons.text_fields,
    _Tool.sound => Icons.volume_up_outlined,
    _Tool.music => Icons.music_note_outlined,
    _Tool.voice => Icons.mic_none,
    _Tool.stickers => Icons.emoji_emotions_outlined,
    _Tool.link => Icons.link_rounded,
  };

  // ---------------------------------------------------------------- timeline

  static const double _tlPad = 18;

  /// Most zoom: 400 px for one second.
  static const double _tlMaxPxPerMs = 0.4;

  /// The white line's time (what you see in the middle of the timeline).
  int get _tlMs {
    if (_tlScroll.hasClients && _tlPx > 0) {
      return (_tlScroll.offset / _tlPx).round().clamp(0, _item.durationMs);
    }
    return _video?.value.position.inMilliseconds ?? _item.trimStart;
  }

  /// Every frame: the timeline follows the playing video (smooth, also
  /// between the player's position updates).
  void _onTlTick(Duration elapsed) {
    final c = _video;
    if (c == null ||
        !_videoReady ||
        _tlUser ||
        _pinching ||
        !_tlScroll.hasClients ||
        _tlPx <= 0) {
      return;
    }
    final now = DateTime.now();
    if (now.isBefore(_tlHoldUntil)) {
      _tlClock.reset();
      return;
    }
    final v = c.value;
    final ms = _tlClock.position(
      reported: v.position.inMilliseconds,
      playing: v.isPlaying,
      nowMs: elapsed.inMilliseconds,
      speed: v.playbackSpeed,
    );
    final pos = _tlScroll.position;
    final t = (ms.clamp(0, _item.durationMs) * _tlPx).clamp(
      0.0,
      pos.maxScrollExtent,
    );
    if ((pos.pixels - t).abs() > 0.5) _tlScroll.jumpTo(t);
  }

  void _tlSeek({bool force = false}) {
    final c = _video;
    if (c == null) return;
    final now = DateTime.now();
    if (!force && now.difference(_tlSeekAt).inMilliseconds < 60) return;
    _tlSeekAt = now;
    final ms = _tlMs.clamp(_item.trimStart, _item.endMs);
    _tlClock.reset();
    c.seekTo(Duration(milliseconds: ms));
  }

  bool _onTlScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.horizontal) return false;
    final c = _video;
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _tlUser = true;
      _tlWasPlaying = c?.value.isPlaying ?? false;
      if (_tlWasPlaying && !_recording) c?.pause();
    } else if (n is ScrollUpdateNotification && _tlUser) {
      _tlSeek();
    } else if (n is ScrollEndNotification && _tlUser) {
      _tlUser = false;
      _tlSeek(force: true);
      // wait for the player to get there (no jump back)
      _tlHoldUntil = DateTime.now().add(const Duration(milliseconds: 450));
      // v0.15: touching the timeline pauses (press play to go on)
    }
    return false;
  }

  // ---- pinch to zoom (two fingers on the timeline)
  double _pinchSpan() {
    final p = _tlPtrs.values.toList();
    if (p.length < 2) return 1;
    return math.max(24.0, (p[0].dx - p[1].dx).abs());
  }

  void _tlPointerDown(PointerDownEvent e) {
    _tlPtrs[e.pointer] = e.localPosition;
    // v0.15: touching the timeline pauses the video
    final c = _video;
    if (c != null && c.value.isPlaying && !_recording) {
      c.pause();
      _tlWasPlaying = false;
    }
    if (_tlPtrs.length == 2 && _tlBasePx > 0) {
      _pinchDist = _pinchSpan();
      _pinchZoom = _tlZoom;
      _pinchAnchor = _tlMs;
      _tlUser = false;
      setState(() => _pinching = true);
    }
  }

  void _tlPointerMove(PointerMoveEvent e) {
    if (!_tlPtrs.containsKey(e.pointer)) return;
    _tlPtrs[e.pointer] = e.localPosition;
    if (!_pinching || _tlBasePx <= 0) return;
    final maxZoom = math.max(1.0, _tlMaxPxPerMs / _tlBasePx);
    final z = (_pinchZoom * _pinchSpan() / _pinchDist).clamp(1.0, maxZoom);
    if ((z - _tlZoom).abs() < 0.01) return;
    setState(() => _tlZoom = z);
    // keep the same time under the white line
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tlScroll.hasClients) return;
      final t = (_pinchAnchor * _tlBasePx * _tlZoom).clamp(
        0.0,
        _tlScroll.position.maxScrollExtent,
      );
      _tlScroll.jumpTo(t);
    });
  }

  void _tlPointerUp(PointerEvent e) {
    _tlPtrs.remove(e.pointer);
    if (_pinching && _tlPtrs.length < 2) {
      setState(() => _pinching = false);
      _tlHoldUntil = DateTime.now().add(const Duration(milliseconds: 200));
    }
  }

  /// v0.14: Android's edge "back" swipe must not steal the trim handles.
  void _syncGestureExclusion() {
    final box = _tlKey.currentContext?.findRenderObject();
    if (!mounted || box is! RenderBox || !box.hasSize || !box.attached) {
      GestureExclusion.instance.clear();
      return;
    }
    final mq = MediaQuery.of(context);
    final r = box.localToGlobal(Offset.zero) & box.size;
    GestureExclusion.instance.set(
      r,
      screenWidth: mq.size.width,
      devicePixelRatio: mq.devicePixelRatio,
    );
  }

  /// v0.14 timeline (like CapCut):
  /// - the white line stays in the middle; slide the timeline to move in
  ///   the video, pinch with two fingers to zoom in / out,
  /// - Split cuts the video at the white line; tap a part to select it,
  ///   then drag ITS lime handles to trim that part (the first / last
  ///   part's outer handles trim the whole video),
  /// - voice over and texts / stickers: drag to move, drag the ends to
  ///   choose when a text shows.
  Widget _timeline() {
    final item = _item;
    final c = _video;
    if (!item.isVideo || c == null || !_videoReady || item.durationMs <= 0) {
      return const SizedBox.shrink();
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _syncGestureExclusion(),
    );
    final total = item.durationMs;
    final start = item.trimStart, end = item.endMs;
    final cuts = item.activeCuts;
    final maxLen = maxVideoMs(widget.mode);
    final segs = item.segments;
    final sel = segs.length == 1
        ? 0
        : (_selSeg != null && _selSeg! < segs.length ? _selSeg : null);
    return LayoutBuilder(
      builder: (context, box) {
        final vw = box.maxWidth;
        final half = vw / 2;
        _tlBasePx = math.max(1.0, vw - _tlPad * 2) / total;
        final px = _tlBasePx * _tlZoom;
        _tlPx = px;
        final contentW = vw + total * px;
        double xOf(int ms) => half + ms.clamp(0, total) * px;
        int msPerPx(double dx) => (dx / px).round();

        // ---- trim handles of the selected part
        void preview(int ms) {
          _tlClock.reset();
          c.seekTo(Duration(milliseconds: ms));
        }

        void dragEdge(int i, bool left, double dx) {
          final list = item.segments;
          if (i >= list.length) return;
          final seg = list[i];
          final kept = item.keptOf(seg) ?? seg;
          final first = i == 0, last = i == list.length - 1;
          final target = _edgeBase + msPerPx(_edgeDx += dx);
          const min = EditItem.minPartMs;
          setState(() {
            if (left && first) {
              // outer edge = trim start of the whole video
              final ns = _clampMs(
                target,
                math.max(0, item.endMs - maxLen),
                kept.endMs - min,
              );
              item.trimStart = ns;
              item.setKept(VideoCut(ns, seg.endMs), ns, kept.endMs);
              preview(ns);
            } else if (!left && last) {
              final ne = _clampMs(
                target,
                kept.startMs + min,
                math.min(total, item.trimStart + maxLen),
              );
              item.trimEnd = ne;
              item.setKept(VideoCut(seg.startMs, ne), kept.startMs, ne);
              preview(math.max(kept.startMs, ne - 400));
            } else if (left) {
              final ns = _clampMs(target, seg.startMs, kept.endMs - min);
              item.setKept(seg, ns, kept.endMs);
              preview(ns);
            } else {
              final ne = _clampMs(target, kept.startMs + min, seg.endMs);
              item.setKept(seg, kept.startMs, ne);
              preview(math.max(kept.startMs, ne - 400));
            }
          });
        }

        void edgeStart(int i, bool left) {
          if (c.value.isPlaying) c.pause();
          final list = item.segments;
          if (i >= list.length) return;
          final kept = item.keptOf(list[i]) ?? list[i];
          _edgeBase = left ? kept.startMs : kept.endMs;
          _edgeDx = 0;
        }

        void edgeDone() {
          _attachVoicePreview();
          setState(() {});
        }

        Widget handle(int i, double x, {required bool left}) {
          return Positioned(
            key: ValueKey(left ? 'trim-start-$i' : 'trim-end-$i'),
            left: x - (left ? 16 : 0),
            width: 16,
            top: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (_) => edgeStart(i, left),
              onHorizontalDragUpdate: (d) => dragEdge(i, left, d.delta.dx),
              onHorizontalDragEnd: (_) => edgeDone(),
              onHorizontalDragCancel: edgeDone,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.lime,
                  borderRadius: BorderRadius.horizontal(
                    left: left ? const Radius.circular(6) : Radius.zero,
                    right: left ? Radius.zero : const Radius.circular(6),
                  ),
                ),
                alignment: Alignment.center,
                child: Container(width: 3, height: 16, color: Colors.black54),
              ),
            ),
          );
        }

        Widget bar({
          required Key key,
          required int s,
          required int e,
          required Color color,
          required Widget label,
          bool selected = false,
          VoidCallback? onTap,
          GestureDragStartCallback? onMoveStart,
          GestureDragUpdateCallback? onMove,
          VoidCallback? onDone,
          GestureDragUpdateCallback? onStart,
          GestureDragUpdateCallback? onEnd,
        }) {
          final left = xOf(s), right = xOf(e);
          final width = math.max(24.0, right - left);
          final keyName = (key as ValueKey).value;
          Widget end(bool isStart, GestureDragUpdateCallback f) => Positioned(
            left: isStart ? -10 : null,
            right: isStart ? null : -10,
            top: -2,
            bottom: -2,
            width: 24,
            child: GestureDetector(
              key: ValueKey('$keyName-${isStart ? 'start' : 'end'}'),
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: f,
              onHorizontalDragEnd: (_) => onDone?.call(),
              child: const _Handle(),
            ),
          );
          return Positioned(
            key: key,
            left: left,
            width: width,
            top: 2,
            bottom: 2,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              onHorizontalDragStart: onMoveStart,
              onHorizontalDragUpdate: onMove,
              onHorizontalDragEnd: onMove == null
                  ? null
                  : (_) => onDone?.call(),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: selected ? 0.6 : 0.32),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: selected ? Colors.white : color,
                          width: selected ? 1.6 : 1,
                        ),
                      ),
                      child: label,
                    ),
                  ),
                  if (onStart != null) end(true, onStart),
                  if (onEnd != null) end(false, onEnd),
                ],
              ),
            ),
          );
        }

        Text barText(String t) => Text(
          t,
          maxLines: 1,
          overflow: TextOverflow.clip,
          textScaler: TextScaler.noScaling,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        );

        Widget row(double h, List<Widget> children) => SizedBox(
          height: h,
          width: contentW,
          child: Stack(clipBehavior: Clip.none, children: children),
        );

        // ---- video row: frames, parts (tap = select), trims, deleted parts
        final thumbs = item.thumbs;
        final slots = (total * px / 44).ceil().clamp(1, 400);
        final videoRow = row(48, [
          Positioned(
            left: half,
            width: total * px,
            top: 0,
            bottom: 0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Row(
                children: [
                  for (var k = 0; k < slots; k++)
                    Expanded(
                      child: Builder(
                        builder: (_) {
                          final idx = thumbs == null
                              ? -1
                              : ((k + 0.5) / slots * thumbs.length)
                                    .floor()
                                    .clamp(0, thumbs.length - 1);
                          final b = idx >= 0 ? thumbs![idx] : null;
                          return b != null
                              ? Image.memory(
                                  b as Uint8List,
                                  fit: BoxFit.cover,
                                  height: 48,
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
          ),
          // outside the trim (drag the outer handles to get it back)
          Positioned(
            left: half,
            width: math.max(0, xOf(start) - half),
            top: 0,
            bottom: 0,
            child: Container(color: Colors.black.withValues(alpha: 0.72)),
          ),
          Positioned(
            left: xOf(end),
            width: math.max(0, xOf(total) - xOf(end)),
            top: 0,
            bottom: 0,
            child: Container(color: Colors.black.withValues(alpha: 0.72)),
          ),
          // trimmed / deleted bits inside the parts
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
                    ? const Icon(Icons.close, size: 16, color: AppColors.like)
                    : null,
              ),
            ),
          // the parts: tap to select
          for (var i = 0; i < segs.length; i++)
            Positioned(
              key: ValueKey('tl-part-$i'),
              left: xOf(segs[i].startMs),
              width: math.max(4.0, xOf(segs[i].endMs) - xOf(segs[i].startMs)),
              top: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _selSeg = _selSeg == i ? null : i);
                },
              ),
            ),
          // gaps between the parts
          for (var i = 1; i < segs.length; i++)
            Positioned(
              key: ValueKey('tl-split-${segs[i].startMs}'),
              left: xOf(segs[i].startMs) - 1.5,
              width: 3,
              top: 0,
              bottom: 0,
              child: const IgnorePointer(
                child: ColoredBox(color: Colors.black),
              ),
            ),
          // the selected part: lime frame + its own handles
          if (sel != null)
            ...() {
              final kept = item.keptOf(segs[sel]);
              if (kept == null) return const <Widget>[];
              return <Widget>[
                Positioned(
                  key: const ValueKey('tl-selected'),
                  left: xOf(kept.startMs),
                  width: math.max(0, xOf(kept.endMs) - xOf(kept.startMs)),
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.symmetric(
                          horizontal: BorderSide(
                            color: AppColors.lime,
                            width: 2.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                handle(sel, xOf(kept.startMs), left: true),
                handle(sel, xOf(kept.endMs), left: false),
              ];
            }(),
        ]);

        // ---- voice over: drag to move
        Widget? voiceRow;
        if (item.hasVoice) {
          final vs = VideoTime.sourceAt(item.voiceStartMs, start, cuts);
          final ve = VideoTime.sourceAt(
            item.voiceStartMs + item.voiceDurMs,
            start,
            cuts,
          );
          voiceRow = row(26, [
            bar(
              key: const ValueKey('tl-voice'),
              s: vs,
              e: math.min(ve, end),
              color: const Color(0xFF4DA3FF),
              label: barText('🎤 Voice ${durationLabel(item.voiceDurMs)}'),
              selected: _tool == _Tool.voice,
              onTap: () => setState(() => _tool = _Tool.voice),
              onMoveStart: (_) {
                if (c.value.isPlaying) c.pause();
                setState(() => _tool = _Tool.voice);
              },
              onMove: (d) {
                final src =
                    (VideoTime.sourceAt(
                              item.voiceStartMs,
                              item.trimStart,
                              item.activeCuts,
                            ) +
                            msPerPx(d.delta.dx))
                        .clamp(item.trimStart, item.endMs);
                final played = VideoTime.playedAt(
                  src,
                  item.trimStart,
                  item.activeCuts,
                );
                setState(
                  () => item.voiceStartMs = played.clamp(
                    0,
                    math.max(0, item.playedMs - 300),
                  ),
                );
              },
              onDone: _attachVoicePreview,
            ),
          ]);
        }

        final rows = <Widget>[
          videoRow,
          if (_audio != null && _musicAllowed)
            row(22, [
              bar(
                key: const ValueKey('tl-music'),
                s: start,
                e: end,
                color: AppColors.lime,
                label: barText('♪ ${_audio!.name}'),
                selected: _tool == _Tool.music,
                onTap: () => setState(() => _tool = _Tool.music),
              ),
            ]),
          if (item.hasVoice) voiceRow!,
          for (var i = 0; i < item.overlays.length; i++)
            row(28, [
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

                void select() => setState(() {
                  _selOverlay = i;
                  _tool = o.isSticker ? _Tool.stickers : _Tool.text;
                });

                return bar(
                  key: ValueKey('tl-ov-$i'),
                  s: s0,
                  e: e0,
                  color: o.isSticker
                      ? const Color(0xFFFFC53D)
                      : const Color(0xFFB97CFF),
                  label: o.isSticker && StickerPack.isPack(o.text)
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: StickerImage(text: o.text, width: 34),
                        )
                      : barText(o.isSticker ? o.text : 'T  ${o.text}'),
                  selected: sel,
                  onTap: select,
                  // v0.13: drag right away (no need to select first)
                  onMoveStart: (_) {
                    if (c.value.isPlaying) c.pause();
                    if (!sel) select();
                  },
                  onMove: (d) {
                    final cur = item.overlays[i];
                    final cs = math.max(cur.startMs, item.trimStart);
                    final ce = cur.endMs > 0
                        ? math.min(cur.endMs, item.endMs)
                        : item.endMs;
                    final l = ce - cs;
                    final ns = (cs + msPerPx(d.delta.dx)).clamp(
                      item.trimStart,
                      item.endMs - l,
                    );
                    setTimes(ns, ns + l);
                  },
                  onStart: (d) {
                    final cur = item.overlays[i];
                    final cs = math.max(cur.startMs, item.trimStart);
                    final ce = cur.endMs > 0
                        ? math.min(cur.endMs, item.endMs)
                        : item.endMs;
                    setTimes(
                      (cs + msPerPx(d.delta.dx)).clamp(
                        item.trimStart,
                        ce - 300,
                      ),
                      ce,
                    );
                  },
                  onEnd: (d) {
                    final cur = item.overlays[i];
                    final cs = math.max(cur.startMs, item.trimStart);
                    final ce = cur.endMs > 0
                        ? math.min(cur.endMs, item.endMs)
                        : item.endMs;
                    setTimes(
                      cs,
                      (ce + msPerPx(d.delta.dx)).clamp(cs + 300, item.endMs),
                    );
                  },
                );
              }(),
            ]),
        ];

        final scroller = NotificationListener<ScrollNotification>(
          onNotification: _onTlScroll,
          child: SingleChildScrollView(
            key: const ValueKey('editor-timeline-scroll'),
            controller: _tlScroll,
            scrollDirection: Axis.horizontal,
            physics: _pinching
                ? const NeverScrollableScrollPhysics()
                : const ClampingScrollPhysics(),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              // tap an empty place: go there, nothing selected
              onTapUp: (d) {
                final ms = ((d.localPosition.dx - half) / px).round().clamp(
                  0,
                  total,
                );
                setState(() => _selSeg = null);
                _tlScroll.animateTo(
                  ms * px,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                );
                _tlHoldUntil = DateTime.now().add(
                  const Duration(milliseconds: 500),
                );
                preview(ms.clamp(start, end));
              },
              child: SizedBox(
                width: contentW,
                child: Column(mainAxisSize: MainAxisSize.min, children: rows),
              ),
            ),
          ),
        );

        return Column(
          key: const ValueKey('editor-timeline'),
          mainAxisSize: MainAxisSize.min,
          children: [
            _timelineTools(c, segs, sel),
            Listener(
              key: _tlKey,
              onPointerDown: _tlPointerDown,
              onPointerMove: _tlPointerMove,
              onPointerUp: _tlPointerUp,
              onPointerCancel: _tlPointerUp,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 156),
                child: Stack(
                  children: [
                    SingleChildScrollView(
                      physics: const ClampingScrollPhysics(),
                      padding: const EdgeInsets.only(top: 2, bottom: 6),
                      child: scroller,
                    ),
                    // the white line (always in the middle)
                    Positioned(
                      key: const ValueKey('tl-playhead'),
                      left: half - 1,
                      top: 0,
                      bottom: 0,
                      width: 2,
                      child: const IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            boxShadow: [
                              BoxShadow(color: Colors.black54, blurRadius: 3),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Time + Split / Delete / Bring back (they act on the selected part, or
  /// the part under the white line).
  Widget _timelineTools(
    VideoPlayerController c,
    List<VideoCut> segs,
    int? sel,
  ) {
    final item = _item;
    return SizedBox(
      height: 34,
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: c,
        builder: (context, v, _) {
          final pos = v.position.inMilliseconds;
          final played = VideoTime.playedAt(
            pos,
            item.trimStart,
            item.activeCuts,
          );
          final target = _targetPart(segs, sel);
          final onCut = target != null && item.keptOf(target) == null;
          Widget tool(
            String k,
            IconData icon,
            String label,
            VoidCallback? f, {
            Color? color,
          }) => TextButton.icon(
            key: ValueKey(k),
            onPressed: f,
            style: TextButton.styleFrom(
              foregroundColor: color ?? Colors.white,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: const TextStyle(
                fontFamily: AppTheme.fontFamily,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            icon: Icon(icon, size: 17),
            label: Text(label),
          );
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: _tlPad - 6),
            child: Row(
              children: [
                // v0.15: play / pause next to the timeline
                IconButton(
                  key: const ValueKey('tl-play'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                  onPressed: () {
                    if (v.isPlaying) {
                      c.pause();
                    } else {
                      final end = item.endMs;
                      if (pos >= end - 80) {
                        c.seekTo(Duration(milliseconds: item.trimStart));
                      }
                      c.play();
                    }
                  },
                  icon: Icon(
                    v.isPlaying
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_circle_fill_rounded,
                    size: 30,
                    color: AppColors.lime,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: Text(
                    '${durationLabel(played)} / ${durationLabel(item.playedMs)}',
                    key: const ValueKey('tl-time'),
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Spacer(),
                tool(
                  'split-here',
                  Icons.vertical_split_outlined,
                  'Split',
                  _splitHere,
                ),
                tool(
                  'split-delete',
                  Icons.delete_outline,
                  'Delete',
                  segs.length > 1 && !onCut ? _deletePart : null,
                  color: AppColors.like,
                ),
                if (item.cuts.isNotEmpty || item.splits.isNotEmpty)
                  tool(
                    'split-restore',
                    Icons.undo,
                    onCut ? 'Bring back' : 'Reset',
                    _restorePart,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// clamp that never throws (lo wins when lo > hi).
  static int _clampMs(int v, int lo, int hi) =>
      v < lo ? lo : (v > hi ? math.max(lo, hi) : v);

  /// The part the tools work on: the selected one, else the one under the
  /// white line.
  VideoCut? _targetPart(List<VideoCut> segs, int? sel) {
    if (sel != null && sel < segs.length) return segs[sel];
    final i = _item.segmentIndexAt(_tlMs);
    return i >= 0 ? segs[i] : null;
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
                            onTap: () {
                              setState(() => _tool = t);
                              // v0.15: stickers open big, at once
                              if (t == _Tool.stickers) _openStickerSheet();
                            },
                            // big phone font: shrink, never overflow
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Column(
                              mainAxisSize: MainAxisSize.min,
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
    this.font = '',
  });
  final String text;
  final Color color;
  final double size;
  final bool background;
  final bool delete;

  /// v0.16: font id (see BioFont).
  final String font;
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
  late String _font = BioFont.normalize(widget.initial?.font);

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
            style: BioFont.style(
              _font,
              TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: _color == Colors.black ? Colors.white : _color,
              ),
            ),
            decoration: const InputDecoration(
              hintText: 'Type something…',
              border: InputBorder.none,
            ),
          ),
          // v0.16: fonts for moment / post texts
          BioFontPicker(
            key: const ValueKey('text-fonts'),
            value: _font,
            small: true,
            keyPrefix: 'text-font',
            onChanged: (v) => setState(() => _font = v),
          ),
          const SizedBox(height: 8),
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
                    font: _font,
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
