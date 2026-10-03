import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_compress/video_compress.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/media_url.dart';
import '../../core/theme.dart';
import '../../core/responsive.dart';
import '../../core/ui.dart';
import '../../services/media_server.dart';
import '../../services/post_service.dart';
import '../../services/media_service.dart';
import '../../widgets/pill_tabs.dart';

class CreatePostScreen extends StatefulWidget {
  const CreatePostScreen({super.key});

  @override
  State<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends State<CreatePostScreen> {
  int _mode = 0; // 0 = post (photo), 1 = clips (video)
  File? _image;
  int? _imageKb;

  File? _video;
  File? _videoThumb;
  int _videoSeconds = 0;
  int _videoW = 0;
  int _videoH = 0;

  final _caption = TextEditingController();
  bool _busy = false;
  String _stage = '';
  double? _progress;

  @override
  void dispose() {
    _caption.dispose();
    if (_busy) VideoCompress.cancelCompression();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_rounded),
                title: const Text(
                  'Choose from gallery',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                onTap: () => Navigator.pop(ctx, ImageSource.gallery),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_rounded),
                title: const Text(
                  'Take a photo',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                onTap: () => Navigator.pop(ctx, ImageSource.camera),
              ),
            ],
          ),
        ),
      ),
    );
    if (source == null) return;
    try {
      // Compressed on the phone before upload (1080px, JPEG q70).
      final file = await MediaService.pickPostImage(source);
      if (file == null) return;
      final bytes = await file.length();
      if (!mounted) return;
      setState(() {
        _image = file;
        _imageKb = (bytes / 1024).round();
      });
    } catch (e) {
      if (mounted) showToast(context, 'Could not open the picker.');
    }
  }

  Future<void> _pickVideo() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.video_library_rounded),
                title: const Text(
                  'Choose a video',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                onTap: () => Navigator.pop(ctx, ImageSource.gallery),
              ),
              ListTile(
                leading: const Icon(Icons.videocam_rounded),
                title: const Text(
                  'Record a video',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                onTap: () => Navigator.pop(ctx, ImageSource.camera),
              ),
            ],
          ),
        ),
      ),
    );
    if (source == null) return;
    try {
      final picked = await ImagePicker().pickVideo(
        source: source,
        maxDuration: const Duration(seconds: kMaxVideoSeconds),
      );
      if (picked == null) return;
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
        // a thumbnail is nice to have; the server can make one too
      }
      if (!mounted) return;
      setState(() {
        _video = File(picked.path);
        _videoThumb = thumb;
        _videoSeconds = seconds;
        _videoW = w;
        _videoH = h;
      });
    } catch (e) {
      if (mounted) showToast(context, 'Could not open that video.');
    }
  }

  bool get _canShare {
    if (_busy) return false;
    return _mode == 0 ? _image != null : _video != null;
  }

  Future<void> _share() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _progress = null;
      _stage = _mode == 0 ? 'Uploading...' : 'Optimising video...';
    });
    try {
      if (_mode == 0) {
        await PostService.instance.createImagePost(
          image: _image!,
          caption: _caption.text,
        );
      } else {
        await _publishVideo();
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publishVideo() async {
    // 1) shrink to 720p on the phone (saves your data and the server's)
    final sub = VideoCompress.compressProgress$.subscribe((p) {
      if (mounted) setState(() => _progress = (p / 100).clamp(0.0, 1.0));
    });
    MediaInfo? info;
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
    final out = info?.file;
    if (out == null) {
      throw const MediaException(
        'Could not process that video. Try another one.',
      );
    }

    // 2) upload to the media server (Telegram storage)
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
      duration: _videoSeconds,
      width: w,
      height: h,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          ),
          title: const Text('Create'),
        ),
        body: ContentWidth(
          maxWidth: 640,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                  children: [
                    PillTabs(
                      labels: const ['Post', 'Clips'],
                      icons: const [
                        Icons.image_rounded,
                        Icons.smart_display_rounded,
                      ],
                      index: _mode,
                      onChanged: (i) {
                        if (!_busy) setState(() => _mode = i);
                      },
                    ),
                    const SizedBox(height: 18),
                    if (_mode == 0)
                      _photoPicker(context)
                    else
                      _videoPicker(context),
                    const SizedBox(height: 16),
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
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _photoPicker(BuildContext context) {
    if (_image == null) {
      return GestureDetector(
        onTap: _busy ? null : _pickImage,
        child: AspectRatio(
          aspectRatio: 4 / 4.6,
          child: Container(
            decoration: BoxDecoration(
              color: context.card,
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: context.hairline, width: 1.5),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    gradient: AppTheme.voltGradient,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: const Icon(
                    Icons.add_photo_alternate_rounded,
                    size: 38,
                    color: AppTheme.ink,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Pick a photo for your post',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  'Shrunk on your phone first to save space',
                  style: TextStyle(color: context.muted),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(32),
      child: AspectRatio(
        aspectRatio: 4 / 5,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(_image!, fit: BoxFit.cover),
            Positioned(
              left: 12,
              bottom: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.compress_rounded,
                      size: 16,
                      color: AppTheme.volt,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${_imageKb ?? 0} KB after compression',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              right: 12,
              top: 12,
              child: GestureDetector(
                onTap: _busy ? null : _pickImage,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.volt,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Text(
                    'Change',
                    style: TextStyle(
                      color: AppTheme.ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _videoPicker(BuildContext context) {
    if (_video == null) {
      return GestureDetector(
        onTap: _busy ? null : _pickVideo,
        child: AspectRatio(
          aspectRatio: 4 / 4.6,
          child: Container(
            decoration: BoxDecoration(
              color: context.card,
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: context.hairline, width: 1.5),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    gradient: AppTheme.voltGradient,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: const Icon(
                    Icons.video_call_rounded,
                    size: 40,
                    color: AppTheme.ink,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Upload a clip',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  'Up to $kMaxVideoSeconds seconds. Vertical looks best.',
                  style: TextStyle(color: context.muted),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(32),
      child: AspectRatio(
        aspectRatio: 4 / 5,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_videoThumb != null)
              Image.file(_videoThumb!, fit: BoxFit.cover)
            else
              ColoredBox(color: context.cardHigh),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black45],
                  stops: [0.6, 1],
                ),
              ),
            ),
            Center(
              child: Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(
                  color: Colors.black45,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 44,
                ),
              ),
            ),
            Positioned(
              left: 12,
              bottom: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.timer_outlined,
                      size: 16,
                      color: AppTheme.volt,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      formatDuration(_videoSeconds),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!_busy)
              Positioned(
                right: 12,
                top: 12,
                child: GestureDetector(
                  onTap: _pickVideo,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.volt,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Text(
                      'Change',
                      style: TextStyle(
                        color: AppTheme.ink,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            if (_busy && _progress != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 6,
                  color: AppTheme.volt,
                  backgroundColor: Colors.white24,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
