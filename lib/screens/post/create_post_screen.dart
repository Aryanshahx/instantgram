import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/media_url.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/music.dart';
import '../../services/media_server.dart';
import '../../services/media_service.dart';
import '../../services/mp4_faststart.dart';
import '../../services/photo_edit.dart';
import '../../services/music_player.dart';
import '../../services/post_service.dart';
import '../../widgets/music_widgets.dart';
import '../../widgets/pill_tabs.dart';
import 'photo_editor_screen.dart';
import 'video_editor_screen.dart';

/// Two steps:
///  1. Preview: a clean 9:16 frame that only shows your photo or clip (never stretched or
///     cropped: it is fitted inside the frame). The pick / change / next buttons sit below it.
///  2. Details: caption, quality switch and the Publish button.
/// Clips above this bitrate are saved as a lighter copy by default.
const double kSmoothMbps = 8;

class CreatePostScreen extends StatefulWidget {
  const CreatePostScreen({super.key, @visibleForTesting this.debugImage});

  /// Tests only: starts with this photo already picked.
  final File? debugImage;

  @override
  State<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends State<CreatePostScreen> {
  int _mode = 0; // 0 = post (photo), 1 = clips (video, or a photo with music)
  bool _clipPhoto = false; // in Clips: false = video, true = photo clip
  MusicTrack? _music;
  double _musicVol = 0.8;
  bool _keepSound = true;
  int _clipSeconds = 10; // length of a photo clip
  int _step = 0; // 0 = preview, 1 = details

  File? _image; // what gets uploaded (the original, or its edited copy)
  File? _imageOriginal;
  PhotoEdits? _imageEdits;
  int _imageBytes = 0;

  File? _video;
  File? _videoThumb;
  int _videoSeconds = 0; // length that will be published (after trimming)
  int _videoSecondsFull = 0;
  int _videoBytes = 0;
  bool _original = true; // upload the clip exactly as recorded
  int _videoW = 0;
  int _videoH = 0;
  VideoEdits? _videoEdits;

  /// Live preview of the picked clip (silent until the user taps the frame to pause).
  VideoPlayerController? _preview;
  bool _previewPaused = false;

  final _caption = TextEditingController();
  bool _busy = false;
  String _stage = '';
  double? _progress;
  int _totalBytes = 0;
  final Stopwatch _clock = Stopwatch();
  DateTime _lastTick = DateTime.fromMillisecondsSinceEpoch(0);

  MusicPlayer?
  _previewMusic; // the chosen track, heard while you look at the preview

  @override
  void initState() {
    super.initState();
    final dbg = widget.debugImage;
    if (dbg != null) {
      _image = dbg;
      _imageOriginal = dbg;
      _imageBytes = dbg.lengthSync();
    }
    // the Publish button needs a title
    _caption.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _caption.dispose();
    _previewMusic?.dispose();
    _preview?.dispose();
    _dropEditedCopy();
    if (_busy) VideoCompress.cancelCompression();
    super.dispose();
  }

  bool get _photoClip => _mode == 1 && _clipPhoto;

  /// Post and photo clips pick a photo; video clips pick a video.
  bool get _isImageMode => _mode == 0 || _clipPhoto;

  // ------------------------------------------------------------------ picking

  Future<ImageSource?> _askSource({
    required IconData galleryIcon,
    required String galleryText,
    required IconData cameraIcon,
    required String cameraText,
  }) {
    return showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(galleryIcon),
                title: Text(
                  galleryText,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                onTap: () => Navigator.pop(ctx, ImageSource.gallery),
              ),
              ListTile(
                leading: Icon(cameraIcon),
                title: Text(
                  cameraText,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                onTap: () => Navigator.pop(ctx, ImageSource.camera),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Post: photo. Clips: one picker for photos and videos (see [_pickClip]).
  VoidCallback get _pickMedia => _mode == 0 ? _pickImage : _pickClip;

  Future<void> _pickImage() async {
    final source = await _askSource(
      galleryIcon: Icons.photo_library_rounded,
      galleryText: 'Choose from gallery',
      cameraIcon: Icons.photo_camera_rounded,
      cameraText: 'Take a photo',
    );
    if (source == null) return;
    try {
      // Posts are uploaded exactly as taken; the bucket keeps the original.
      final file = _mode == 1
          ? await MediaService.pickClipImage(source)
          : await MediaService.pickPostImage(source);
      if (file == null) return;
      await _useImage(file);
    } catch (e) {
      if (mounted) {
        showToast(
          context,
          e is MediaException ? e.message : 'Could not open the picker.',
        );
      }
    }
  }

  /// Clips: the user picks any photo or video, then adds audio in the preview.
  Future<void> _pickClip() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final o in const [
                (
                  'gallery',
                  Icons.perm_media_rounded,
                  'Photo or video from gallery',
                ),
                ('photo', Icons.photo_camera_rounded, 'Take a photo'),
                ('video', Icons.videocam_rounded, 'Record a video'),
              ])
                ListTile(
                  leading: Icon(o.$2),
                  title: Text(
                    o.$3,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  onTap: () => Navigator.pop(ctx, o.$1),
                ),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return;
    try {
      if (choice == 'photo') {
        final f = await MediaService.pickClipImage(ImageSource.camera);
        if (f != null) await _useImage(f);
      } else if (choice == 'video') {
        final v = await ImagePicker().pickVideo(
          source: ImageSource.camera,
          maxDuration: const Duration(seconds: kMaxVideoSeconds),
        );
        if (v != null) await _useVideo(v.path);
      } else {
        final x = await ImagePicker().pickMedia(
          maxWidth: 1600,
          maxHeight: 2400,
          imageQuality: 90,
        );
        if (x == null) return;
        final f = File(x.path);
        if (await MediaService.isSupportedImage(f)) {
          await _useImage(f);
        } else {
          await _useVideo(x.path);
        }
      }
    } catch (e) {
      if (mounted) {
        showToast(
          context,
          e is MediaException ? e.message : 'Could not open the picker.',
        );
      }
    }
  }

  Future<void> _useImage(File file) async {
    final bytes = await file.length();
    if (!mounted) return;
    _dropEditedCopy();
    if (_mode == 1) await _dropVideo();
    if (!mounted) return;
    setState(() {
      _image = file;
      _imageOriginal = file;
      _imageEdits = null;
      _imageBytes = bytes;
      if (_mode == 1) _clipPhoto = true;
      _previewPaused = false;
    });
    _syncPreview();
  }

  /// Forgets the picked video (a clip is either a video or a photo).
  Future<void> _dropVideo() async {
    final old = _preview;
    old?.removeListener(_previewTick);
    _preview = null;
    _video = null;
    _videoThumb = null;
    _videoEdits = null;
    _videoSeconds = 0;
    _videoSecondsFull = 0;
    _videoBytes = 0;
    await old?.dispose();
  }

  Future<void> _useVideo(String path) async {
    try {
      final bytes = await File(path).length();
      final info = await VideoCompress.getMediaInfo(path);
      final seconds = ((info.duration ?? 0) / 1000).ceil();
      if (seconds > kMaxVideoSeconds + 1) {
        if (mounted) {
          showToast(
            context,
            'Clips can be up to $kMaxVideoSeconds seconds. This one is $seconds s.',
          );
        }
        return;
      }
      var w = info.width ?? 0;
      var h = info.height ?? 0;
      if ((info.orientation ?? 0) % 180 == 90) {
        final t = w;
        w = h;
        h = t;
      }
      File? thumb;
      try {
        thumb = await VideoCompress.getFileThumbnail(path, quality: 70);
      } catch (_) {
        // a thumbnail is nice to have; the clip works without one
      }
      if (!mounted) return;
      _dropEditedCopy();
      setState(() {
        _image = null;
        _imageOriginal = null;
        _imageEdits = null;
        _imageBytes = 0;
        _clipPhoto = false;
        _video = File(path);
        _videoThumb = thumb;
        _videoSeconds = seconds;
        _videoSecondsFull = seconds;
        _videoBytes = bytes;
        _videoW = w;
        _videoH = h;
        _videoEdits = null;
        _previewPaused = false;
        // Heavy files (high bitrate) buffer for viewers on mobile data, so they are saved as a
        // lighter 720p copy by default. "Original quality" is one tap away.
        _original = !(seconds > 0 && bytes * 8 / seconds / 1e6 > kSmoothMbps);
      });
      await _startPreview(File(path));
    } catch (e) {
      if (mounted) showToast(context, 'Could not open that video.');
    }
  }

  // ------------------------------------------------------------ video preview

  Future<void> _startPreview(File file) async {
    final old = _preview;
    if (mounted) setState(() => _preview = null);
    await old?.dispose();
    final c = VideoPlayerController.file(file);
    try {
      await c.initialize();
      await c.setLooping(true);
      await c.setVolume(_videoPreviewVolume);
      c.addListener(_previewTick);
      if (!mounted || _video?.path != file.path) {
        await c.dispose();
        return;
      }
      setState(() => _preview = c);
      _syncPreview();
    } catch (_) {
      await c.dispose(); // the frame then shows the thumbnail instead
    }
  }

  /// Keeps the preview inside the trimmed part of the clip.
  void _previewTick() {
    final c = _preview;
    final e = _videoEdits;
    if (c == null || e == null || !e.trimmed) return;
    final pos = c.value.position;
    if (pos >= Duration(seconds: e.end) ||
        pos < Duration(seconds: e.start) - const Duration(milliseconds: 400)) {
      c.seekTo(Duration(seconds: e.start));
    }
  }

  void _dropEditedCopy({File? except}) {
    final i = _image;
    final o = _imageOriginal;
    if (i != null && o != null && i.path != o.path && i.path != except?.path) {
      i.delete().ignore();
    }
  }

  Future<void> _edit() async {
    if (_isImageMode) {
      final src = _imageOriginal;
      if (src == null) return;
      final r = await Navigator.of(context).push<PhotoEditResult>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) =>
              PhotoEditorScreen(original: src, initial: _imageEdits),
        ),
      );
      if (r == null || !mounted) return;
      final bytes = await r.file.length();
      _dropEditedCopy(except: r.file);
      if (!mounted) return;
      setState(() {
        _image = r.file;
        _imageEdits = r.edits.isEmpty ? null : r.edits;
        _imageBytes = bytes;
      });
    } else {
      final f = _video;
      if (f == null) return;
      _preview?.pause();
      final r = await Navigator.of(context).push<VideoEdits>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => VideoEditorScreen(file: f, initial: _videoEdits),
        ),
      );
      if (!mounted) return;
      if (r != null) {
        setState(() {
          _videoEdits = r.isEmpty ? null : r;
          _videoSeconds = r.isEmpty ? _videoSecondsFull : r.length;
        });
        final c = _preview;
        if (c != null) {
          await c.setVolume(_videoPreviewVolume);
          await c.seekTo(Duration(seconds: r.trimmed ? r.start : 0));
        }
      }
      _syncPreview();
    }
  }

  /// Sound of the clip in the preview: off when it was muted, or when the audio you added
  /// should replace it.
  double get _videoPreviewVolume =>
      (_videoEdits?.mute == true || (_music != null && !_keepSound)) ? 0 : 1;

  void _syncPreview() {
    final showing = _step == 0 && !_busy && !_previewPaused && _hasMedia;
    final c = _preview;
    if (c != null) {
      if (showing && _mode == 1 && !_clipPhoto) {
        c.setVolume(_videoPreviewVolume);
        c.play();
      } else {
        c.pause();
      }
    }
    final m = _previewMusic;
    if (m != null) {
      m.setVolume(_musicVol);
      showing ? m.play() : m.pause();
    }
  }

  void _togglePreview() {
    final canToggle =
        (_mode == 1 && !_clipPhoto && _preview != null) ||
        _previewMusic != null;
    if (!canToggle) return;
    setState(() => _previewPaused = !_previewPaused);
    _syncPreview();
  }

  /// Chooses (or removes) the audio and starts playing it in the preview.
  Future<void> _setMusic(MusicTrack? t) async {
    final old = _previewMusic;
    _previewMusic = null;
    setState(() => _music = t);
    await old?.dispose();
    if (t == null) {
      _syncPreview();
      return;
    }
    final p = MusicPlayer(t);
    await p.init(volume: _musicVol);
    if (!mounted || _music?.id != t.id) {
      await p.dispose();
      return;
    }
    _previewMusic = p;
    _syncPreview();
  }

  // --------------------------------------------------------------- publishing

  bool get _hasMedia => _isImageMode ? _image != null : _video != null;

  /// A title is required; a photo clip also needs audio (that is what makes it a clip).
  bool get _canShare =>
      !_busy &&
      _hasMedia &&
      _caption.text.trim().isNotEmpty &&
      (!_photoClip || _music != null);

  void _go(int step) {
    setState(() => _step = step);
    _syncPreview();
  }

  void _onProgress(double p) {
    if (!mounted) return;
    final now = DateTime.now();
    if (p < 0.999 && now.difference(_lastTick).inMilliseconds < 120) return;
    _lastTick = now;
    setState(() {
      if (p >= 0.999) {
        // the file is on its way to the bucket; only the quick check is left
        _stage = 'Finishing...';
        _progress = null;
      } else {
        _progress = p;
      }
    });
  }

  Future<void> _share() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _progress = null;
      _totalBytes = 0;
      _stage = (!_isImageMode && _willShrink)
          ? 'Processing video...'
          : (!_isImageMode ? 'Getting ready...' : 'Uploading...');
    });
    _syncPreview();
    try {
      if (_isImageMode) {
        _totalBytes = _imageBytes;
        _clock
          ..reset()
          ..start();
        setState(() => _progress = 0);
        final dims = await PhotoEditor.probeSize(_image!);
        await PostService.instance.createImagePost(
          image: _image!,
          caption: _caption.text.trim(),
          onProgress: _onProgress,
          width: dims?.width.round() ?? 0,
          height: dims?.height.round() ?? 0,
          musicId: _music?.id,
          musicVolume: _musicVol,
          clip: _photoClip,
          clipSeconds: _clipSeconds,
        );
      } else {
        await _publishVideo();
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    } finally {
      _clock.stop();
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _willShrink =>
      !_original ||
      _videoBytes > kMaxVideoMb * 1024 * 1024 ||
      _videoEdits != null;

  static String _mb(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).round()} KB';

  Future<void> _publishVideo() async {
    // 1) Original quality: the file is uploaded untouched. It is only saved again (at up to
    //    1080p, or 720p when "Original quality" is off) when the clip was edited, when the
    //    user turned the switch off, or when it is bigger than the service accepts.
    File out = _video!;
    MediaInfo? info;
    if (_willShrink) {
      final sub = VideoCompress.compressProgress$.subscribe((p) {
        if (mounted) setState(() => _progress = (p / 100).clamp(0.0, 1.0));
      });
      final ve = _videoEdits;
      final cut = ve != null && ve.trimmed;
      try {
        info = await VideoCompress.compressVideo(
          _video!.path,
          quality: _original
              ? VideoQuality.Res1920x1080Quality
              : VideoQuality.Res1280x720Quality,
          deleteOrigin: false,
          startTime: cut ? ve.start : null,
          duration: cut ? ve.length : null,
          includeAudio: !(ve?.mute ?? false),
        );
      } finally {
        sub.unsubscribe();
      }
      final shrunk = info?.file;
      if (shrunk == null) {
        throw const MediaException(
          'Could not process that video. Try another one.',
        );
      }
      out = shrunk;
    }

    // 2) Put the index of the video at the front so it starts playing straight away for
    //    viewers. Nothing is re-encoded; the picture and sound bytes stay identical.
    if (mounted) {
      setState(() {
        _stage = 'Getting ready...';
        _progress = null;
      });
    }
    final fast = await Mp4FastStart.run(out);
    final tempCopy = fast.path != out.path ? fast : null;
    out = fast;

    try {
      // 3) upload straight to the Tigris bucket
      _totalBytes = await out.length();
      _clock
        ..reset()
        ..start();
      if (mounted) {
        setState(() {
          _stage = 'Uploading...';
          _progress = 0;
        });
      }
      // proportions: the picked file's (already turned upright); a saved copy keeps them
      var w = _videoW;
      var h = _videoH;
      if (w == 0 || h == 0) {
        w = info?.width ?? 0;
        h = info?.height ?? 0;
      }
      final media = await MediaServer.instance.uploadVideo(
        file: out,
        thumb: _videoThumb,
        onProgress: _onProgress,
      );
      if (mounted) setState(() => _stage = 'Publishing...');
      await PostService.instance.createVideoPost(
        media: media,
        caption: _caption.text.trim(),
        duration: _videoSeconds,
        width: w,
        height: h,
        musicId: _music?.id,
        musicVolume: _musicVol,
        keepSound: _keepSound,
      );
    } finally {
      tempCopy?.delete().ignore();
    }
    VideoCompress.deleteAllCache();
  }

  /// "31.2 of 74.0 MB  ·  2.8 MB/s"
  String get _uploadDetail {
    final p = _progress;
    if (p == null || _totalBytes <= 0 || _stage != 'Uploading...') return '';
    final sent = (p * _totalBytes).round();
    final secs = _clock.elapsedMilliseconds / 1000;
    final speed = (secs >= 1 && sent > 0)
        ? '  \u00b7  ${(sent / secs / (1024 * 1024)).toStringAsFixed(1)} MB/s'
        : '';
    return '${_mb(sent)} of ${_mb(_totalBytes)}$speed';
  }

  // --------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy && _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy && _step == 1) _go(0);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: Icon(
              _step == 0 ? Icons.close_rounded : Icons.arrow_back_rounded,
            ),
            onPressed: _busy
                ? null
                : () => _step == 0 ? Navigator.of(context).pop(false) : _go(0),
          ),
          title: Text(_step == 0 ? 'Create' : 'Details'),
        ),
        body: ContentWidth(
          maxWidth: 640,
          child: _step == 0 ? _previewStep(context) : _detailsStep(context),
        ),
      ),
    );
  }

  // ---- step 1: preview ----

  Widget _previewStep(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: PillTabs(
            labels: const ['Post', 'Clips'],
            icons: const [Icons.image_rounded, Icons.smart_display_rounded],
            index: _mode,
            onChanged: (i) {
              setState(() {
                _mode = i;
                // a photo picked in Post becomes a photo clip in Clips
                if (i == 1) _clipPhoto = _image != null;
              });
              _syncPreview();
            },
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _hasMedia ? _togglePreview : (_pickMedia),
              child: _frame(context, _previewContent(context)),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
            child: _hasMedia
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _audioBar(context),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _pickMedia,
                              icon: const Icon(Icons.swap_horiz_rounded),
                              label: const Text('Change'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _edit,
                              icon: const Icon(Icons.tune_rounded),
                              label: const Text('Edit'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () {
                            if (_photoClip && _music == null) {
                              showToast(
                                context,
                                'Add audio to make a clip from a photo.',
                              );
                              _audioSheet();
                              return;
                            }
                            _go(1);
                          },
                          icon: const Icon(Icons.arrow_forward_rounded),
                          label: const Text('Next'),
                        ),
                      ),
                    ],
                  )
                : SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _pickMedia,
                      icon: Icon(
                        _mode == 0
                            ? Icons.add_photo_alternate_rounded
                            : Icons.video_call_rounded,
                      ),
                      label: Text(
                        _mode == 0
                            ? 'Choose a photo'
                            : 'Choose a video or photo',
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  /// The biggest 9:16 frame that fits the space. Nothing is drawn on top of the media.
  Widget _frame(BuildContext context, Widget child, {double? maxWidth}) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = math.min(
          math.min(c.maxWidth, maxWidth ?? double.infinity),
          c.maxHeight * 9 / 16,
        );
        return Center(
          child: SizedBox(
            key: const ValueKey('previewFrame'),
            width: w,
            height: w * 16 / 9,
            child: ClipRect(
              child: ColoredBox(color: const Color(0xFF0A0A0A), child: child),
            ),
          ),
        );
      },
    );
  }

  Widget _previewContent(BuildContext context) {
    if (!_hasMedia) {
      return Center(
        child: Icon(
          _mode == 0 ? Icons.image_outlined : Icons.smart_display_outlined,
          size: 64,
          color: Colors.white24,
        ),
      );
    }
    if (_isImageMode) {
      return SizedBox.expand(
        child: Image.file(
          _image!,
          fit: BoxFit.contain,
          cacheWidth: 1600,
          filterQuality: FilterQuality.medium,
        ),
      );
    }
    return _videoContent();
  }

  /// The clip, fitted inside the frame (never stretched or cropped).
  Widget _videoContent() {
    final c = _preview;
    if (c != null && c.value.isInitialized) {
      return SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: c.value.size.width,
            height: c.value.size.height,
            child: VideoPlayer(c),
          ),
        ),
      );
    }
    final t = _videoThumb;
    return t == null
        ? const SizedBox.shrink()
        : SizedBox.expand(child: Image.file(t, fit: BoxFit.contain));
  }

  // ---- step 2: details ----

  Widget _detailsStep(BuildContext context) {
    final isVideo = !_isImageMode;
    final thumb = isVideo
        ? (_videoThumb == null
              ? const SizedBox.shrink()
              : SizedBox.expand(
                  child: Image.file(_videoThumb!, fit: BoxFit.contain),
                ))
        : SizedBox.expand(
            child: Image.file(_image!, fit: BoxFit.contain, cacheWidth: 400),
          );

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 96,
                    height: 96 * 16 / 9,
                    child: _frame(context, thumb, maxWidth: 96),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _mode == 1 ? 'Clip' : 'Photo',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(
                              Icons.high_quality_rounded,
                              size: 16,
                              color: AppTheme.volt,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                _summary(),
                                style: TextStyle(
                                  color: context.muted,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (_music != null) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(
                                Icons.music_note_rounded,
                                size: 16,
                                color: AppTheme.volt,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  _music!.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: context.muted,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _caption,
                enabled: !_busy,
                maxLines: 3,
                minLines: 2,
                maxLength: 200,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  hintText: 'Give it a title',
                  helperText: 'Required',
                ),
              ),
              if (isVideo) ...[
                const SizedBox(height: 12),
                _qualityTile(context),
              ],
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_busy) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: _progress,
                      minHeight: 6,
                      color: AppTheme.volt,
                      backgroundColor: context.cardHigh,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_uploadDetail.isNotEmpty)
                    Text(
                      _uploadDetail,
                      style: TextStyle(
                        color: context.muted,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _canShare ? _share : null,
                    icon: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: AppTheme.ink,
                            ),
                          )
                        : const Icon(Icons.bolt_rounded),
                    label: Text(
                      _busy
                          ? (_progress == null
                                ? _stage
                                : '$_stage ${(_progress! * 100).round()}%')
                          : 'Publish',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _summary() {
    if (_isImageMode) {
      final base =
          '${_imageEdits != null ? 'Edited' : 'Original'}  \u00b7  ${_mb(_imageBytes)}';
      return _photoClip ? '$base  \u00b7  ${_clipSeconds}s' : base;
    }
    final e = _videoEdits;
    final tags = <String>[
      formatDuration(_videoSeconds),
      _mb(_videoBytes),
      if (e != null && e.trimmed) 'Trimmed',
      if (e != null && e.mute) 'No sound',
    ];
    return tags.join('  \u00b7  ');
  }

  /// The audio row under the preview: tap it to choose music, set the volume and more.
  Widget _audioBar(BuildContext context) {
    final m = _music;
    final needed = _photoClip && m == null;
    return Material(
      color: context.card,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        key: const ValueKey('audioBar'),
        borderRadius: BorderRadius.circular(18),
        onTap: _busy ? null : _audioSheet,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: const BoxDecoration(
                  color: AppTheme.volt,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.music_note_rounded,
                  size: 18,
                  color: AppTheme.ink,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  m == null
                      ? (needed ? 'Add audio to make this a clip' : 'Add audio')
                      : '${m.title}  \u00b7  ${(_musicVol * 100).round()}%',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              Icon(
                m == null ? Icons.add_rounded : Icons.tune_rounded,
                color: context.muted,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _audioSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final m = _music;
          void both(VoidCallback f) {
            setState(f);
            setSheet(() {});
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Audio',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: const BoxDecoration(
                          color: AppTheme.volt,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.music_note_rounded,
                          color: AppTheme.ink,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m == null ? 'No audio yet' : m.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                            Text(
                              m == null
                                  ? (_photoClip
                                        ? 'A photo clip needs audio'
                                        : 'Pick a track from InstantGram music')
                                  : '${m.mood}  \u00b7  ${m.bpm} BPM',
                              style: TextStyle(
                                color: context.muted,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 44),
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                        ),
                        onPressed: () async {
                          _previewMusic?.pause();
                          final t = await pickMusic(ctx, currentId: m?.id);
                          if (t != null && mounted) {
                            await _setMusic(t);
                            setSheet(() {});
                          } else {
                            _syncPreview();
                          }
                        },
                        child: Text(m == null ? 'Choose' : 'Change'),
                      ),
                    ],
                  ),
                  if (m != null) ...[
                    Row(
                      children: [
                        Icon(
                          Icons.volume_up_rounded,
                          size: 20,
                          color: context.muted,
                        ),
                        Expanded(
                          child: Slider(
                            value: _musicVol,
                            min: 0.1,
                            onChanged: (v) {
                              both(() => _musicVol = v);
                              _previewMusic?.setVolume(v);
                            },
                          ),
                        ),
                        Text(
                          '${(_musicVol * 100).round()}%',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                    if (!_isImageMode)
                      SwitchListTile(
                        value: _keepSound,
                        onChanged: (v) {
                          both(() => _keepSound = v);
                          _preview?.setVolume(_videoPreviewVolume);
                        },
                        activeTrackColor: AppTheme.volt,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          "Keep the clip's own sound",
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                  ],
                  if (_photoClip) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Length',
                      style: TextStyle(
                        color: context.muted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final sec in const [5, 10, 15, 20, 30])
                          ChoiceChip(
                            label: Text('${sec}s'),
                            selected: _clipSeconds == sec,
                            onSelected: (_) => both(() => _clipSeconds = sec),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (m != null)
                        TextButton.icon(
                          onPressed: () async {
                            await _setMusic(null);
                            setSheet(() {});
                          },
                          icon: const Icon(Icons.delete_outline_rounded),
                          label: const Text('Remove audio'),
                        ),
                      const Spacer(),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(110, 50),
                        ),
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    _syncPreview();
  }

  String _qualityText(bool big) {
    if (big && _original) {
      return 'This file is over $kMaxVideoMb MB, so it will be shrunk to fit.';
    }
    if (!_original) {
      final heavy =
          _videoSecondsFull > 0 &&
          _videoBytes * 8 / _videoSecondsFull / 1e6 > kSmoothMbps;
      return heavy
          ? 'This clip is very heavy (${(_videoBytes * 8 / _videoSecondsFull / 1e6).round()} Mbps) and would buffer for viewers, so it is saved as a smooth 720p copy first. Turn on Original quality to upload it as recorded.'
          : 'Saved at 720p on your phone first. Smaller, so it uploads and plays faster.';
    }
    final mbps = _videoSecondsFull > 0
        ? _videoBytes * 8 / _videoSecondsFull / 1e6
        : 0;
    final edited = _videoEdits != null
        ? ' Edited clips are saved again at up to 1080p.'
        : '';
    if (mbps > 15) {
      return 'Uploaded as recorded (${mbps.round()} Mbps). Heavy clips like this can '
          'buffer on slow connections: turn this off for smoother playback.$edited';
    }
    return 'Uploaded exactly as recorded. Big files take longer to upload and to load for viewers.$edited';
  }

  Widget _qualityTile(BuildContext context) {
    final big = _videoBytes > kMaxVideoMb * 1024 * 1024;
    return Container(
      decoration: BoxDecoration(
        color: context.card,
        borderRadius: BorderRadius.circular(24),
      ),
      child: SwitchListTile(
        value: _original,
        onChanged: _busy ? null : (v) => setState(() => _original = v),
        activeTrackColor: AppTheme.volt,
        contentPadding: const EdgeInsets.fromLTRB(18, 4, 12, 4),
        title: const Text(
          'Original quality',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          _qualityText(big),
          style: TextStyle(color: context.muted, fontSize: 12.5, height: 1.3),
        ),
      ),
    );
  }
}
