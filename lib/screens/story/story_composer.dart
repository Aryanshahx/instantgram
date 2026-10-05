import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/music.dart';
import '../../models/story.dart';
import '../../services/media_service.dart';
import '../../services/music_player.dart';
import '../../services/story_service.dart';
import '../../widgets/music_widgets.dart';
import '../../widgets/story_overlays.dart';

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
      if (seconds > kMaxStorySeconds + 1) {
        if (context.mounted) {
          showToast(
            context,
            'Moments can be up to $kMaxStorySeconds seconds. This video is $seconds s.',
          );
        }
        return false;
      }
      try {
        thumb = await VideoCompress.getFileThumbnail(x.path, quality: 70);
      } catch (_) {
        // the cover is nice to have
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

const _colors = <int>[
  0xFFFFFFFF,
  0xFF0B0D12,
  0xFFD2FF3F,
  0xFF4DF0B4,
  0xFFFF5C6C,
  0xFF7B6CFF,
  0xFFFFD43B,
];

const _emojis = [
  '😀',
  '😂',
  '😍',
  '🥰',
  '😎',
  '🤩',
  '😭',
  '😡',
  '🔥',
  '💯',
  '❤️',
  '💜',
  '💚',
  '✨',
  '🎉',
  '🥳',
  '👍',
  '👏',
  '🙌',
  '🙏',
  '💪',
  '👀',
  '🎶',
  '🎧',
  '🌈',
  '☀️',
  '🌙',
  '⭐',
  '🌸',
  '🍕',
  '🍔',
  '☕',
  '📍',
  '✈️',
  '🏖️',
  '⚽',
  '🎮',
  '📸',
  '💥',
  '🚀',
];

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
    return showModalBottomSheet<StoryOverlay>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TextSheet(start: start, canDelete: canDelete),
    );
  }

  Future<void> _addEmoji() async {
    final e = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: GridView.count(
            shrinkWrap: true,
            crossAxisCount: 8,
            children: [
              for (final e in _emojis)
                InkWell(
                  key: ValueKey('emoji_$e'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.pop(ctx, e),
                  child: Center(
                    child: Text(e, style: const TextStyle(fontSize: 28)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (e == null) return;
    setState(() => _overlays.add(StoryOverlay(text: e, dy: 0.45, emoji: true)));
  }

  Future<void> _tapOverlay(int i) async {
    final o = _overlays[i];
    if (o.emoji) {
      final ok = await confirm(
        context,
        title: 'Remove sticker?',
        confirmLabel: 'Remove',
        destructive: true,
      );
      if (ok && mounted) setState(() => _overlays.removeAt(i));
      return;
    }
    final r = await _editText(o, canDelete: true);
    if (!mounted) return;
    if (r == null) return;
    setState(() {
      if (r.text.isEmpty) {
        _overlays.removeAt(i);
      } else {
        _overlays[i] = r;
      }
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
              child: chip,
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
                        'Music',
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

class _TextSheet extends StatefulWidget {
  const _TextSheet({required this.start, required this.canDelete});
  final StoryOverlay start;
  final bool canDelete;

  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  late final TextEditingController _c = TextEditingController(
    text: widget.start.text,
  );
  late int _color = widget.start.color;
  late bool _pill = widget.start.pill;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  StoryOverlay get _result =>
      widget.start.copyWith(text: _c.text.trim(), color: _color, pill: _pill);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
        left: 20,
        right: 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('storyTextInput'),
            controller: _c,
            autofocus: true,
            maxLength: 120,
            maxLines: 3,
            minLines: 1,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Type something...'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final c in _colors)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Container(
                    width: 32,
                    height: 32,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: Color(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: c == _color ? AppTheme.violet : Colors.grey,
                        width: c == _color ? 3 : 1,
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              FilterChip(
                key: const ValueKey('storyPill'),
                label: const Text('Box'),
                selected: _pill,
                onSelected: (v) => setState(() => _pill = v),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (widget.canDelete)
                TextButton(
                  key: const ValueKey('storyTextDelete'),
                  onPressed: () =>
                      Navigator.pop(context, widget.start.copyWith(text: '')),
                  child: const Text(
                    'Remove',
                    style: TextStyle(color: AppTheme.coral),
                  ),
                ),
              const Spacer(),
              FilledButton(
                key: const ValueKey('storyTextDone'),
                style: FilledButton.styleFrom(minimumSize: const Size(110, 46)),
                onPressed: () => Navigator.pop(context, _result),
                child: const Text('Done'),
              ),
            ],
          ),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}
