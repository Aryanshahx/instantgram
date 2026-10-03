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
import '../../services/media_server.dart';
import '../../services/media_service.dart';
import '../../services/post_service.dart';
import '../../widgets/pill_tabs.dart';

/// Two steps:
///  1. Preview: a clean 9:16 frame that only shows your photo or clip (never stretched or
///     cropped: it is fitted inside the frame). The pick / change / next buttons sit below it.
///  2. Details: caption, quality switch and the Publish button.
class CreatePostScreen extends StatefulWidget {
  const CreatePostScreen({super.key});

  @override
  State<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends State<CreatePostScreen> {
  int _mode = 0; // 0 = post (photo), 1 = clips (video)
  int _step = 0; // 0 = preview, 1 = details

  File? _image;
  int _imageBytes = 0;

  File? _video;
  File? _videoThumb;
  int _videoSeconds = 0;
  int _videoBytes = 0;
  bool _original = true; // upload the clip exactly as recorded
  int _videoW = 0;
  int _videoH = 0;

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

  @override
  void dispose() {
    _caption.dispose();
    _preview?.dispose();
    if (_busy) VideoCompress.cancelCompression();
    super.dispose();
  }

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

  Future<void> _pickImage() async {
    final source = await _askSource(
      galleryIcon: Icons.photo_library_rounded,
      galleryText: 'Choose from gallery',
      cameraIcon: Icons.photo_camera_rounded,
      cameraText: 'Take a photo',
    );
    if (source == null) return;
    try {
      // Uploaded exactly as taken; the bucket keeps the original.
      final file = await MediaService.pickPostImage(source);
      if (file == null) return;
      final bytes = await file.length();
      if (!mounted) return;
      setState(() {
        _image = file;
        _imageBytes = bytes;
      });
    } catch (e) {
      if (mounted) {
        showToast(
          context,
          e is MediaException ? e.message : 'Could not open the picker.',
        );
      }
    }
  }

  Future<void> _pickVideo() async {
    final source = await _askSource(
      galleryIcon: Icons.video_library_rounded,
      galleryText: 'Choose a video',
      cameraIcon: Icons.videocam_rounded,
      cameraText: 'Record a video',
    );
    if (source == null) return;
    try {
      final picked = await ImagePicker().pickVideo(
        source: source,
        maxDuration: const Duration(seconds: kMaxVideoSeconds),
      );
      if (picked == null) return;
      final bytes = await File(picked.path).length();
      final info = await VideoCompress.getMediaInfo(picked.path);
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
        thumb = await VideoCompress.getFileThumbnail(picked.path, quality: 70);
      } catch (_) {
        // a thumbnail is nice to have; the clip works without one
      }
      if (!mounted) return;
      setState(() {
        _video = File(picked.path);
        _videoThumb = thumb;
        _videoSeconds = seconds;
        _videoBytes = bytes;
        _videoW = w;
        _videoH = h;
        _previewPaused = false;
      });
      await _startPreview(File(picked.path));
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

  void _syncPreview() {
    final c = _preview;
    if (c == null) return;
    final show = _mode == 1 && _step == 0 && !_busy && !_previewPaused;
    if (show) {
      c.play();
    } else {
      c.pause();
    }
  }

  void _togglePreview() {
    if (_mode != 1 || _preview == null) return;
    setState(() => _previewPaused = !_previewPaused);
    _syncPreview();
  }

  // --------------------------------------------------------------- publishing

  bool get _hasMedia => _mode == 0 ? _image != null : _video != null;

  bool get _canShare => !_busy && _hasMedia;

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
      _stage = (_mode == 1 && _willShrink)
          ? 'Optimising video...'
          : 'Uploading...';
    });
    _syncPreview();
    try {
      if (_mode == 0) {
        _totalBytes = _imageBytes;
        _clock
          ..reset()
          ..start();
        setState(() => _progress = 0);
        await PostService.instance.createImagePost(
          image: _image!,
          caption: _caption.text,
          onProgress: _onProgress,
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

  bool get _willShrink => !_original || _videoBytes > kMaxVideoMb * 1024 * 1024;

  static String _mb(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).round()} KB';

  Future<void> _publishVideo() async {
    // 1) original quality: upload the file untouched. Only shrink to 720p when the user
    //    switched "Original quality" off, or when the file is bigger than the service accepts.
    File out = _video!;
    MediaInfo? info;
    if (_willShrink) {
      final sub = VideoCompress.compressProgress$.subscribe((p) {
        if (mounted) setState(() => _progress = (p / 100).clamp(0.0, 1.0));
      });
      try {
        info = await VideoCompress.compressVideo(
          _video!.path,
          quality: VideoQuality.Res1280x720Quality,
          deleteOrigin: false,
          includeAudio: true,
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

    // 2) upload straight to the Tigris bucket
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
    var w = info?.width ?? _videoW;
    var h = info?.height ?? _videoH;
    if (w == 0 || h == 0) {
      w = _videoW;
      h = _videoH;
    }
    final media = await MediaServer.instance.uploadVideo(
      file: out,
      thumb: _videoThumb,
      onProgress: _onProgress,
    );
    if (mounted) setState(() => _stage = 'Publishing...');
    await PostService.instance.createVideoPost(
      media: media,
      caption: _caption.text,
      duration: _videoSeconds,
      width: w,
      height: h,
    );
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
              setState(() => _mode = i);
              _syncPreview();
            },
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _hasMedia
                  ? _togglePreview
                  : (_mode == 0 ? _pickImage : _pickVideo),
              child: _frame(context, _previewContent(context)),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
            child: _hasMedia
                ? Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _mode == 0 ? _pickImage : _pickVideo,
                          icon: const Icon(Icons.swap_horiz_rounded),
                          label: const Text('Change'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: FilledButton.icon(
                          onPressed: () => _go(1),
                          icon: const Icon(Icons.arrow_forward_rounded),
                          label: const Text('Next'),
                        ),
                      ),
                    ],
                  )
                : SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _mode == 0 ? _pickImage : _pickVideo,
                      icon: Icon(
                        _mode == 0
                            ? Icons.add_photo_alternate_rounded
                            : Icons.video_call_rounded,
                      ),
                      label: Text(
                        _mode == 0 ? 'Choose a photo' : 'Choose a clip',
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
            child: ClipRRect(
              borderRadius: BorderRadius.circular(w < 150 ? 14 : 26),
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
    if (_mode == 0) {
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
    final isVideo = _mode == 1;
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
                          isVideo ? 'Clip' : 'Photo',
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
                                isVideo
                                    ? '${formatDuration(_videoSeconds)}  \u00b7  ${_mb(_videoBytes)}'
                                    : 'Original  \u00b7  ${_mb(_imageBytes)}',
                                style: TextStyle(
                                  color: context.muted,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _caption,
                enabled: !_busy,
                maxLines: 4,
                minLines: 3,
                maxLength: 500,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Say something about it...',
                ),
              ),
              if (isVideo) ...[
                const SizedBox(height: 4),
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
          big && _original
              ? 'This file is over $kMaxVideoMb MB, so it will be shrunk to fit.'
              : _original
              ? 'Uploaded exactly as recorded. Big files take longer to upload and to load for viewers.'
              : 'Shrunk to 720p on your phone first. Smaller, so it uploads and plays faster.',
          style: TextStyle(color: context.muted, fontSize: 12.5, height: 1.3),
        ),
      ),
    );
  }
}
