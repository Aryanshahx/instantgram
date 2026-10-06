import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/music.dart';
import '../../models/story.dart';
import '../../services/media_service.dart';
import '../../services/music_player.dart';
import '../../services/story_service.dart';
import '../post/video_editor_screen.dart';
import '../../widgets/music_widgets.dart';
import '../../widgets/overlay_tools.dart';
import '../../widgets/story_overlays.dart';

/// Saves the kept part of [source] as a new video (a moment can only be so long).
Future<File?> _cutMoment(
  BuildContext context,
  File source,
  VideoEdits e, {
  VideoQuality quality = VideoQuality.Res1920x1080Quality,
}) async {
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            SizedBox(width: 18),
            Expanded(child: Text('Preparing your moment...')),
          ],
        ),
      ),
    ),
  );
  File? out;
  try {
    final info = await VideoCompress.compressVideo(
      source.path,
      quality: quality,
      deleteOrigin: false,
      startTime: e.start,
      duration: e.length,
      includeAudio: !e.mute,
    );
    out = info?.file;
  } catch (_) {
    out = null;
  }
  nav.pop();
  if (out == null && context.mounted) {
    showToast(context, 'Could not trim that video. Try another one.');
  }
  return out;
}

/// "Add to your story": pick a photo or a video, then open the editor. Returns true when a
/// moment was shared.
Future<bool> startStoryFlow(BuildContext context) async {
  final choice = await showModalBottomSheet<({bool video, ImageSource source})>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      Widget tile(IconData icon, String label, bool video, ImageSource s) =>
          ListTile(
            key: ValueKey('story_${video ? 'video' : 'photo'}_${s.name}'),
            leading: Icon(icon),
            title: Text(label),
            onTap: () => Navigator.pop(ctx, (video: video, source: s)),
          );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            tile(
              Icons.photo_library_outlined,
              'Photo from gallery',
              false,
              ImageSource.gallery,
            ),
            tile(
              Icons.photo_camera_outlined,
              'Take a photo',
              false,
              ImageSource.camera,
            ),
            tile(
              Icons.video_library_outlined,
              'Video from gallery',
              true,
              ImageSource.gallery,
            ),
            tile(
              Icons.videocam_outlined,
              'Record a video',
              true,
              ImageSource.camera,
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
  if (choice == null || !context.mounted) return false;
  try {
    File? image;
    File? video;
    File? thumb;
    var seconds = 0;
    if (choice.video) {
      final x = await ImagePicker().pickVideo(
        source: choice.source,
        maxDuration: const Duration(seconds: kMaxStorySeconds),
      );
      if (x == null) return false;
      video = File(x.path);
      final info = await VideoCompress.getMediaInfo(x.path);
      seconds = ((info.duration ?? 0) / 1000).ceil();
      try {
        thumb = await VideoCompress.getFileThumbnail(x.path, quality: 70);
      } catch (_) {
        // the cover is nice to have
      }
      // A video longer than a moment can be is trimmed here instead of being refused.
      if (seconds > kMaxStorySeconds) {
        if (!context.mounted) return false;
        final edits = await Navigator.of(context).push<VideoEdits>(
          MaterialPageRoute(
            builder: (_) => VideoEditorScreen(
              file: video!,
              title: 'Trim your moment',
              maxSeconds: kMaxStorySeconds,
              initial: VideoEdits(
                start: 0,
                end: kMaxStorySeconds,
                total: seconds,
              ),
            ),
          ),
        );
        if (edits == null) return false;
        if (!context.mounted) return false;
        final cut = await _cutMoment(context, video, edits);
        if (cut == null) return false;
        video = cut;
        seconds = edits.length;
        try {
          thumb = await VideoCompress.getFileThumbnail(cut.path, quality: 70);
        } catch (_) {
          // keep the first cover
        }
      } else if (await video.length() > kMaxVideoMb * 1024 * 1024) {
        // too heavy for the media service: save a smaller copy (720p)
        if (!context.mounted) return false;
        final small = await _cutMoment(
          context,
          video,
          VideoEdits(start: 0, end: seconds, total: seconds),
          quality: VideoQuality.Res1280x720Quality,
        );
        if (small == null) return false;
        video = small;
      }
    } else {
      image = await MediaService.pickStoryImage(choice.source);
      if (image == null) return false;
    }
    if (!context.mounted) return false;
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => StoryComposerScreen(
          image: image,
          video: video,
          thumb: thumb,
          seconds: seconds,
        ),
      ),
    );
    if (done == true && context.mounted) {
      showToast(context, 'Moment shared (visible for 24 hours)');
    }
    return done == true;
  } catch (e) {
    if (context.mounted) showToast(context, friendlyError(e));
    return false;
  }
}

/// The moment editor: drag texts and emoji stickers, add music, share.
class StoryComposerScreen extends StatefulWidget {
  const StoryComposerScreen({
    super.key,
    this.image,
    this.video,
    this.thumb,
    this.seconds = 0,
  }) : assert((image == null) != (video == null));

  final File? image;
  final File? video;
  final File? thumb;
  final int seconds;

  @override
  State<StoryComposerScreen> createState() => _StoryComposerScreenState();
}


class _StoryComposerScreenState extends State<StoryComposerScreen> {
  final List<StoryOverlay> _overlays = [];
  VideoPlayerController? _vc;
  MusicPlayer? _player;
  MusicTrack? _track;
  bool _keepSound = true;
  bool _posting = false;
  double _progress = 0;
  Size _canvas = const Size(360, 640);
  double _baseScale = 1;
  int? _sel; // the selected text or sticker

  bool get _isVideo => widget.video != null;

  @override
  void initState() {
    super.initState();
    if (_isVideo) _initVideo();
  }

  Future<void> _initVideo() async {
    final c = VideoPlayerController.file(
      widget.video!,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    try {
      await c.initialize();
      await c.setLooping(true);
      await c.setVolume(_keepSound ? 1 : 0);
      await c.play();
    } catch (_) {
      await c.dispose();
      if (mounted) showToast(context, 'This video cannot be played.');
      return;
    }
    if (!mounted) {
      await c.dispose();
      return;
    }
    setState(() => _vc = c);
  }

  @override
  void dispose() {
    _vc?.dispose();
    _player?.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ tools

  Future<void> _addText() async {
    final r = await _editText(const StoryOverlay(text: ''));
    if (r == null || r.text.trim().isEmpty) return;
    setState(() => _overlays.add(r.copyWith(dx: 0.5, dy: 0.45)));
  }

  Future<StoryOverlay?> _editText(
    StoryOverlay start, {
    bool canDelete = false,
  }) {
    return showOverlayTextSheet(context, start, canDelete: canDelete);
  }

  Future<void> _addEmoji() async {
    final o = await showStickerSheet(context);
    if (o == null || !mounted) return;
    setState(() {
      _overlays.add(o);
      _sel = _overlays.length - 1;
    });
  }

  /// First tap selects (frame, corner handle, size bar); a second tap on a selected text edits it.
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
    final r = await _editText(o, canDelete: true);
    if (!mounted || r == null) return;
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

  Future<void> _music() async {
    final t = await pickMusic(context, currentId: _track?.id);
    if (t == null || !mounted) return;
    final old = _player;
    _player = null;
    await old?.dispose();
    final p = MusicPlayer(t);
    await p.init(volume: 0.8);
    if (!mounted) {
      await p.dispose();
      return;
    }
    _player = p;
    await p.play();
    setState(() => _track = t);
  }

  Future<void> _removeMusic() async {
    final old = _player;
    _player = null;
    setState(() => _track = null);
    await old?.dispose();
  }

  Future<void> _toggleSound() async {
    setState(() => _keepSound = !_keepSound);
    await _vc?.setVolume(_keepSound ? 1 : 0);
  }

  Future<void> _share() async {
    if (_posting) return;
    setState(() {
      _posting = true;
      _progress = 0;
    });
    try {
      await StoryService.instance.addStory(
        image: widget.image,
        video: widget.video,
        thumb: widget.thumb,
        duration: widget.seconds,
        overlays: _overlays,
        musicId: _track?.id ?? '',
        musicTitle: (_track?.remote ?? false) ? _track!.title : '',
        musicArtist: _track?.artist ?? '',
        keepSound: _keepSound,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _posting = false);
        showToast(context, friendlyError(e));
      }
    }
  }

  // ------------------------------------------------------------------ build

  Widget _media() {
    if (!_isVideo) {
      return Image.file(widget.image!, fit: BoxFit.contain);
    }
    final c = _vc;
    if (c == null || !c.value.isInitialized) {
      final t = widget.thumb;
      return t != null
          ? Image.file(t, fit: BoxFit.contain)
          : const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: c.value.size.width,
        height: c.value.size.height,
        child: VideoPlayer(c),
      ),
    );
  }

  Widget _tool(IconData icon, String tip, VoidCallback onTap, {Key? key}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Tooltip(
        message: tip,
        child: GestureDetector(
          key: key,
          onTap: _posting ? null : onTap,
          child: Container(
            width: 46,
            height: 46,
            decoration: const BoxDecoration(
              color: Colors.black54,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // a tap beside the texts and stickers lets go of the selected one
          Positioned.fill(
            child: GestureDetector(
              key: const ValueKey('storyBackground'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (_sel != null) setState(() => _sel = null);
              },
            ),
          ),
          StoryCanvas(
            media: _media(),
            overlays: _overlays,
            onSize: (s) => _canvas = s,
            overlayBuilder: (i, chip) => GestureDetector(
              key: ValueKey('drag$i'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _tapOverlay(i),
              onScaleStart: (_) => _baseScale = _overlays[i].scale,
              onScaleUpdate: (d) {
                final o = _overlays[i];
                setState(() {
                  _overlays[i] = o.copyWith(
                    dx: (o.dx + d.focalPointDelta.dx / _canvas.width).clamp(
                      0.02,
                      0.98,
                    ),
                    dy: (o.dy + d.focalPointDelta.dy / _canvas.height).clamp(
                      0.02,
                      0.98,
                    ),
                    scale: d.pointerCount > 1
                        ? (_baseScale * d.scale).clamp(0.4, 4.0)
                        : o.scale,
                  );
                });
              },
              child: _sel == i && i < _overlays.length
                  ? SelectedOverlayChip(
                      overlay: _overlays[i],
                      canvasWidth: _canvas.width,
                      onScale: _resizeSelected,
                    )
                  : chip,
            ),
          ),
          if (_sel != null && _sel! < _overlays.length)
            Positioned(
              left: 0,
              right: 0,
              bottom: 90,
              child: OverlaySelectionBar(
                dark: false,
                overlay: _overlays[_sel!],
                onScale: _resizeSelected,
                onEdit: !_overlays[_sel!].emoji && !_overlays[_sel!].isImage
                    ? _editSelected
                    : null,
                onDelete: _deleteSelected,
                onDone: () => setState(() => _sel = null),
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _tool(
                    Icons.close_rounded,
                    'Close',
                    () => Navigator.of(context).pop(false),
                    key: const ValueKey('storyClose'),
                  ),
                  const Spacer(),
                  Column(
                    children: [
                      _tool(
                        Icons.text_fields_rounded,
                        'Add text',
                        _addText,
                        key: const ValueKey('storyText'),
                      ),
                      _tool(
                        Icons.emoji_emotions_outlined,
                        'Stickers',
                        _addEmoji,
                        key: const ValueKey('storySticker'),
                      ),
                      _tool(
                        Icons.music_note_rounded,
                        'Audio',
                        _music,
                        key: const ValueKey('storyMusic'),
                      ),
                      if (_isVideo)
                        _tool(
                          _keepSound
                              ? Icons.volume_up_rounded
                              : Icons.volume_off_rounded,
                          _keepSound ? 'Sound on' : 'Sound off',
                          _toggleSound,
                          key: const ValueKey('storySound'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  if (_track != null)
                    Flexible(
                      child: Container(
                        key: const ValueKey('storyTrack'),
                        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.music_note_rounded,
                              color: Colors.white,
                              size: 16,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                _track!.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            InkWell(
                              onTap: _removeMusic,
                              child: const Padding(
                                padding: EdgeInsets.all(6),
                                child: Icon(
                                  Icons.close_rounded,
                                  color: Colors.white70,
                                  size: 16,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const Spacer(),
                  FilledButton(
                    key: const ValueKey('storyShare'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(150, 52),
                      backgroundColor: AppTheme.volt,
                      foregroundColor: AppTheme.ink,
                    ),
                    onPressed: _posting ? null : _share,
                    child: _posting
                        ? Text(
                            _progress > 0 && _progress < 1
                                ? '${(_progress * 100).round()}%'
                                : 'Sharing...',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          )
                        : const Text(
                            'Share moment',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
