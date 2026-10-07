import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../../core/limits.dart';
import '../../core/config.dart';
import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/media_url.dart';
import '../../core/responsive.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/finish.dart';
import '../../models/music.dart';
import '../../models/post.dart';
import '../../models/story.dart' show StoryOverlay, kMaxStorySeconds;
import '../../services/audio_merger.dart';
import '../../services/itunes_service.dart';
import '../../services/media_server.dart';
import '../../services/media_service.dart';
import '../../services/mp4_faststart.dart';
import '../../services/music_player.dart';
import '../../services/overlay_painter.dart';
import '../../services/photo_edit.dart';
import '../../services/post_service.dart';
import '../../services/story_service.dart';
import '../../widgets/music_widgets.dart';
import '../../widgets/overlay_tools.dart';
import '../../widgets/post_media.dart';
import 'editor_screen.dart';
import 'video_editor_screen.dart' show VideoEdits;

/// How loud the chosen music is (it is not a user setting any more).
const double kMusicVolume = 0.8;

/// The video's own sound is never mixed away by the audio: use Mute in the editor for that.
const bool _keepSound = true;

/// One photo or video that is going into the post.
class _Item {
  _Item.photo(File source, this.bytes)
    : video = false,
      original = source,
      file = source;

  _Item.video(File source, this.bytes)
    : video = true,
      original = source,
      file = source;

  final bool video;

  /// The photo or video as it was picked.
  final File original;

  /// Photo: what gets uploaded (the original, or its edited copy). Video: the same as [original].
  File file;
  PhotoEdits? edits;
  int bytes;

  /// Proportions (0 = unknown).
  int width = 0;
  int height = 0;

  // video only
  File? thumb;
  int seconds = 0; // length that will be published (after trimming)
  int secondsFull = 0;
  VideoEdits? videoEdits;
  VideoLook? look;

  /// Texts and stickers (photos: burned into [file], kept here to edit them again).
  List<StoryOverlay> overlays = [];

  /// What viewers see on top of a video.
  MediaFinish? get finish {
    if (!video) return null;
    final f = MediaFinish(overlays: overlays, look: look);
    return f.isEmpty ? null : f;
  }

  double get aspect => (width > 0 && height > 0) ? width / height : 0;
}

/// A video that is ready to go up.
class _Ready {
  _Ready(
    this.file,
    this.temp,
    this.width,
    this.height, {
    this.merged,
    this.seconds,
  });
  final File file;
  final File? temp;
  final int width;
  final int height;

  /// The video with a song mixed in (a temporary file), when that was done.
  final File? merged;

  /// Length of the published video when a song cut it (null = unchanged).
  final int? seconds;
}

/// New post / new clip, in the way people know from Instagram:
///  1. A big preview, a strip with the chosen photos and videos, Edit and Music buttons and the
///     Post | Clips tabs at the bottom. "Next" is on the top right.
///  2. Details: a small picture next to the caption, a few option rows and "Share".
///
/// Post = one photo, or a carousel of up to 10 photos and videos (at least one photo).
/// Clips = one video, or one photo that plays for 5 seconds with music.
class CreatePostScreen extends StatefulWidget {
  const CreatePostScreen({
    super.key,
    @visibleForTesting this.debugImage,
    @visibleForTesting this.debugImages,
  });

  /// Tests only: starts with this photo already picked.
  final File? debugImage;

  /// Tests only: starts with these photos already picked.
  final List<File>? debugImages;

  @override
  State<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends State<CreatePostScreen> {
  int _mode = 0; // 0 = post, 1 = clips

  /// True when the video that was just prepared has its song mixed in.
  bool _baked = false;
  int _step = 0; // 0 = preview, 1 = details

  final List<_Item> _items = [];
  int _sel = 0;

  MusicTrack? _music;

  /// Live preview of the selected video (the photo case shows the picture).
  VideoPlayerController? _preview;
  _Item? _previewFor;
  bool _previewPaused = false;
  int _previewGen = 0;

  /// The chosen track, heard while you look at the preview.
  MusicPlayer? _previewMusic;

  final _caption = TextEditingController();
  bool _busy = false;
  String _stage = '';
  double? _progress;
  int _totalBytes = 0;
  int _sentBytes = 0;

  // details: who sees it, which numbers are shown, and also sharing it as a moment
  String _audience = kAudienceEveryone;
  bool _hideLikes = false;
  bool _hideComments = false;
  bool _hideShares = false;
  bool _alsoStory = false;
  int _coverVer = 0;

  PostOptions get _options => PostOptions(
    audience: _audience,
    hideLikes: _hideLikes,
    hideComments: _hideComments,
    hideShares: _hideShares,
  );
  final Stopwatch _clock = Stopwatch();
  DateTime _lastTick = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    final dbgs = <File>[?widget.debugImage, ...?widget.debugImages];
    for (final f in dbgs) {
      _items.add(_Item.photo(f, f.lengthSync()));
    }
    _caption.addListener(() {
      if (mounted) setState(() {});
    });
    unawaited(MediaServer.instance.warmUp());
  }

  @override
  void dispose() {
    _caption.dispose();
    _previewMusic?.dispose();
    _preview?.dispose();
    for (final i in _items) {
      _dropEditedCopy(i);
    }
    if (_busy) VideoCompress.cancelCompression();
    super.dispose();
  }

  // ------------------------------------------------------------------ state

  _Item? get _first => _items.isEmpty ? null : _items.first;

  /// What the preview shows: the selected item (Post) or the one clip (Clips).
  _Item? get _active {
    if (_items.isEmpty) return null;
    if (_mode == 1) return _items.first;
    return _items[_sel.clamp(0, _items.length - 1)];
  }

  /// What gets published.
  List<_Item> get _chosen => _mode == 1 ? [?_first] : List.of(_items);

  bool get _hasMedia => _items.isNotEmpty;
  bool get _hasPhoto => _chosen.any((i) => !i.video);
  bool get _photoClip => _mode == 1 && _first != null && !_first!.video;

  /// Post needs a photo; a photo clip needs music (that is what makes it a clip).
  bool get _canNext => _mode == 1
      ? (_first != null && (_first!.video || _music != null))
      : _hasPhoto;

  bool get _canShare => !_busy && _canNext && _caption.text.trim().isNotEmpty;

  /// Frame of the preview: the clip's 9:16, or the proportions the post will have.
  double get _frameAspect {
    if (_mode == 1) return 9 / 16;
    final a = _first?.aspect ?? 0;
    return a > 0 ? a.clamp(PostMedia.minAspect, PostMedia.maxAspect) : 4 / 5;
  }

  /// Something that can be played or paused in the preview: a video, or the music.
  bool get _canPlay => (_active?.video ?? false) || _previewMusic != null;

  // ------------------------------------------------------------------ picking

  Future<String?> _askSource() {
    final multi = _mode == 0;
    return showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final o in [
                (
                  'gallery',
                  Icons.perm_media_rounded,
                  multi
                      ? 'Photos and videos from gallery'
                      : 'Photo or video from gallery',
                ),
                ('photo', Icons.photo_camera_rounded, 'Take a photo'),
                ('video', Icons.videocam_rounded, 'Record a video'),
              ])
                ListTile(
                  key: ValueKey('pick_${o.$1}'),
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
  }

  /// Opens the picker. In Post it adds to the strip (up to 10); in Clips it replaces the clip.
  Future<void> _pick() async {
    if (_busy) return;
    final room = _mode == 0 ? kMaxPostItems - _items.length : 1;
    if (room <= 0) {
      showToast(
        context,
        'A post can have up to $kMaxPostItems photos and videos.',
      );
      return;
    }
    final choice = await _askSource();
    if (choice == null || !mounted) return;
    try {
      final picked = <_Item>[];
      if (choice == 'photo') {
        final f = await MediaService.pickPostImage(ImageSource.camera);
        if (f != null) picked.add(await _photoItem(f));
      } else if (choice == 'video') {
        final v = await ImagePicker().pickVideo(
          source: ImageSource.camera,
          maxDuration: const Duration(seconds: kMaxVideoSeconds),
        );
        if (v != null) {
          final it = await _videoItem(v.path);
          if (it != null) picked.add(it);
        }
      } else {
        final files = await MediaService.pickGalleryMedia(limit: room);
        for (final x in files.take(room)) {
          final f = File(x.path);
          if (await MediaService.isSupportedImage(f)) {
            if (await f.length() > kMaxImageMb * 1024 * 1024) {
              if (mounted) {
                showToast(
                  context,
                  'A photo is larger than $kMaxImageMb MB and was skipped.',
                );
              }
              continue;
            }
            picked.add(await _photoItem(f));
          } else {
            final it = await _videoItem(x.path);
            if (it != null) picked.add(it);
          }
        }
      }
      if (picked.isEmpty || !mounted) return;
      _add(picked);
    } catch (e) {
      if (mounted) {
        showToast(
          context,
          e is MediaException ? e.message : 'Could not open the picker.',
        );
      }
    }
  }

  Future<_Item> _photoItem(File f) async {
    final it = _Item.photo(f, await f.length());
    final size = await PhotoEditor.probeSize(f);
    if (size != null) {
      it.width = size.width.round();
      it.height = size.height.round();
    }
    return it;
  }

  /// Reads a video; null (with a message) when it is not usable.
  Future<_Item?> _videoItem(String path) async {
    try {
      final bytes = await File(path).length();
      final info = await VideoCompress.getMediaInfo(path);
      final ms = (info.duration ?? 0).round();
      final seconds = (ms / 1000).ceil();
      if (isVideoTooLong(ms)) {
        if (mounted) showToast(context, videoTooLongMessage(ms));
        return null;
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
        // a thumbnail is nice to have; the video works without one
      }
      return _Item.video(File(path), bytes)
        ..thumb = thumb
        ..seconds = seconds
        ..secondsFull = seconds
        ..width = w
        ..height = h;
    } catch (_) {
      if (mounted) showToast(context, 'Could not open that video.');
      return null;
    }
  }

  void _add(List<_Item> picked) {
    setState(() {
      if (_mode == 1) {
        for (final i in _items) {
          _dropEditedCopy(i);
        }
        _items
          ..clear()
          ..add(picked.first);
        _sel = 0;
      } else {
        _items.addAll(picked);
        _sel = _items.length - picked.length; // show the first new one
      }
      _previewPaused = false;
    });
    unawaited(_ensurePreview());
  }

  void _remove(int i) {
    if (_busy) return;
    final gone = _items[i];
    setState(() {
      _items.removeAt(i);
      _dropEditedCopy(gone);
      var s = _sel;
      if (i < s) s--;
      _sel = _items.isEmpty ? 0 : s.clamp(0, _items.length - 1);
    });
    unawaited(_ensurePreview());
  }

  void _select(int i) {
    if (i == _sel) return;
    setState(() {
      _sel = i;
      _previewPaused = false;
    });
    unawaited(_ensurePreview());
  }

  void _dropEditedCopy(_Item i, {File? except}) {
    if (!i.video &&
        i.file.path != i.original.path &&
        i.file.path != except?.path) {
      i.file.delete().ignore();
    }
  }

  // ------------------------------------------------------------ video preview

  Future<void> _disposePreview() async {
    _previewGen++;
    final old = _preview;
    old?.removeListener(_previewTick);
    _preview = null;
    _previewFor = null;
    await old?.dispose();
  }

  /// Makes the preview player match the selected item (none for a photo).
  Future<void> _ensurePreview() async {
    final it = _active;
    if (it == null || !it.video) {
      if (_preview != null || _previewFor != null) {
        await _disposePreview();
        if (mounted) setState(() {});
      }
      _syncPreview();
      return;
    }
    if (identical(_previewFor, it)) {
      _syncPreview();
      return;
    }
    await _disposePreview();
    final gen = _previewGen;
    _previewFor = it;
    final c = VideoPlayerController.file(
      it.file,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    try {
      await c.initialize();
      await c.setLooping(true);
      await c.setVolume(_previewVolume(it));
      if (!mounted || gen != _previewGen) {
        await c.dispose();
        return;
      }
      c.addListener(_previewTick);
      setState(() => _preview = c);
      _syncPreview();
    } catch (_) {
      await c.dispose(); // the frame then shows the thumbnail instead
    }
  }

  /// Keeps the preview inside the trimmed part of the clip.
  void _previewTick() {
    final c = _preview;
    final e = _previewFor?.videoEdits;
    if (c == null || e == null || !e.trimmed) return;
    final pos = c.value.position;
    if (pos >= Duration(seconds: e.end) ||
        pos < Duration(seconds: e.start) - const Duration(milliseconds: 400)) {
      c.seekTo(Duration(seconds: e.start));
    }
  }

  /// Sound of the video in the preview: off when it was muted in the editor.
  double _previewVolume(_Item it) => it.videoEdits?.mute == true ? 0 : 1;

  void _syncPreview() {
    final showing = _step == 0 && !_busy && !_previewPaused && _hasMedia;
    final c = _preview;
    final it = _previewFor;
    if (c != null && it != null) {
      c.setVolume(_previewVolume(it));
      showing ? c.play() : c.pause();
    }
    final m = _previewMusic;
    if (m != null) {
      m.setVolume(kMusicVolume);
      showing ? m.play() : m.pause();
    }
  }

  void _togglePreview() {
    if (!_canPlay) return;
    setState(() => _previewPaused = !_previewPaused);
    _syncPreview();
  }

  // -------------------------------------------------------------------- music

  /// Opens the music picker; the chosen track plays in the preview.
  Future<void> _chooseMusic() async {
    if (_busy) return;
    _previewMusic?.pause();
    final t = await pickMusic(context, currentId: _music?.id);
    if (!mounted) return;
    if (t != null) {
      _explainSong(t);
      await _setMusic(t);
    } else {
      _syncPreview();
    }
  }

  /// The hit song that will be mixed into the clip (clips with one video only).
  MusicTrack? get _bakeTrack {
    final m = _music;
    final f = _first;
    if (m == null || !m.isApple || _mode != 1 || f == null || !f.video) {
      return null;
    }
    return m;
  }

  /// Tells what a hit song does to a clip.
  void _explainSong(MusicTrack t) {
    if (!t.isApple || _mode != 1 || !(_first?.video ?? false)) return;
    final long = (_first?.seconds ?? 0) > kSongPreviewSeconds;
    showToast(
      context,
      long
          ? 'This song replaces the sound of your video, and the clip is cut to $kSongPreviewSeconds seconds.'
          : 'This song replaces the sound of your video.',
    );
  }

  Future<void> _setMusic(MusicTrack? t) async {
    final old = _previewMusic;
    _previewMusic = null;
    setState(() {
      _music = t;
      _previewPaused = false;
    });
    await old?.dispose();
    if (t == null) {
      _syncPreview();
      return;
    }
    final p = MusicPlayer(t);
    await p.init(volume: kMusicVolume);
    if (!mounted || _music?.id != t.id) {
      await p.dispose();
      return;
    }
    _previewMusic = p;
    _syncPreview();
  }

  // --------------------------------------------------------------------- edit

  Future<void> _edit() async {
    final it = _active;
    if (it == null || _busy) return;
    _preview?.pause();
    _previewMusic?.pause();
    final r = await Navigator.of(context).push<EditorResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => EditorScreen(
          file: it.original,
          video: it.video,
          thumb: it.thumb,
          photoEdits: it.edits,
          videoEdits: it.videoEdits,
          look: it.look,
          overlays: it.overlays,
          music: _music,
        ),
      ),
    );
    if (r == null || !mounted) {
      _syncPreview();
      return;
    }
    if (!it.video) {
      final f = r.photoFile ?? it.original;
      final bytes = await f.length();
      _dropEditedCopy(it, except: f);
      final size = await PhotoEditor.probeSize(f);
      if (!mounted) return;
      setState(() {
        it.file = f;
        it.edits = r.photoEdits;
        it.overlays = r.overlays;
        it.bytes = bytes;
        if (size != null) {
          it.width = size.width.round();
          it.height = size.height.round();
        }
      });
    } else {
      final ve = r.videoEdits;
      setState(() {
        it.videoEdits = ve;
        it.seconds = ve == null ? it.secondsFull : ve.length;
        it.look = r.look;
        it.overlays = r.overlays;
      });
      final c = _preview;
      if (c != null) {
        await c.setVolume(_previewVolume(it));
        await c.seekTo(
          Duration(seconds: ve != null && ve.trimmed ? ve.start : 0),
        );
      }
    }
    if (r.music?.id != _music?.id) {
      await _setMusic(r.music);
    } else {
      _syncPreview();
    }
  }

  // --------------------------------------------------------------- navigation

  void _next() {
    if (_mode == 1 && _first != null && !_first!.video && _music == null) {
      showToast(context, 'Add audio to make a clip from a photo.');
      unawaited(_chooseMusic());
      return;
    }
    if (_mode == 0 && !_hasPhoto) {
      showToast(context, 'A post needs at least one photo.');
      return;
    }
    _go(1);
  }

  void _go(int step) {
    FocusScope.of(context).unfocus();
    setState(() => _step = step);
    _syncPreview();
  }

  void _setMode(int i) {
    if (i == _mode || _busy) return;
    setState(() {
      _mode = i;
      _sel = 0;
      _previewPaused = false;
    });
    unawaited(_ensurePreview());
  }

  // --------------------------------------------------------------- publishing

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

  /// Videos go up exactly as recorded; only an edited (trimmed or muted) video, or one bigger
  /// than the service accepts, is saved again.
  bool _willShrink(_Item it) =>
      it.bytes > kMaxVideoMb * 1024 * 1024 || it.videoEdits != null;

  Future<void> _share() async {
    FocusScope.of(context).unfocus();
    final chosen = _chosen;
    if (chosen.isEmpty) return;
    setState(() {
      _busy = true;
      _progress = null;
      _totalBytes = 0;
      _sentBytes = 0;
      _stage = 'Getting ready...';
    });
    _syncPreview();
    _baked = false;
    final caption = _caption.text.trim();
    final music = _music;
    final title = (music?.remote ?? false) ? music!.title : null;
    final artist = (music?.remote ?? false) && music!.artist.isNotEmpty
        ? music.artist
        : null;
    try {
      // what a moment made from this post would show
      String storyImage = '';
      String storyVideo = '';
      String storyThumb = '';
      int storySecs = 0;
      if (chosen.length == 1 && !chosen.first.video) {
        // one photo (a post, or a photo clip that plays for 5 seconds)
        final it = chosen.first;
        _totalBytes = it.bytes;
        _clock
          ..reset()
          ..start();
        setState(() {
          _stage = 'Uploading...';
          _progress = 0;
        });
        final dims = it.width > 0 && it.height > 0
            ? null
            : await PhotoEditor.probeSize(it.file);
        storyImage = await PostService.instance.createImagePost(
          options: _options,
          image: it.file,
          caption: caption,
          onProgress: _onProgress,
          width: dims?.width.round() ?? it.width,
          height: dims?.height.round() ?? it.height,
          musicId: music?.id,
          musicTitle: title,
          musicArtist: artist,
          musicVolume: kMusicVolume,
          clip: _photoClip,
          clipSeconds: kPhotoClipSeconds,
        );
      } else {
        final up = await _uploadAll(chosen);
        if (mounted) setState(() => _stage = 'Publishing...');
        if (_mode == 1) {
          final r = up.first;
          await PostService.instance.createVideoPost(
            media: UploadedMedia(ref: r.ref, thumbRef: r.thumbRef),
            caption: caption,
            duration: r.seconds,
            width: r.width,
            height: r.height,
            musicId: music?.id,
            musicTitle: title,
            musicArtist: artist,
            musicVolume: kMusicVolume,
            keepSound: _baked ? true : _keepSound,
            musicBaked: _baked,
            finish: chosen.first.finish,
            options: _options,
          );
          storyVideo = r.ref;
          storyThumb = r.thumbRef;
          storySecs = r.seconds;
        } else {
          final f = up.first;
          if (f.video) {
            storyVideo = f.ref;
            storyThumb = f.thumbRef;
            storySecs = f.seconds;
          } else {
            storyImage = f.ref;
          }
          await PostService.instance.createCarouselPost(
            options: _options,
            items: up,
            caption: caption,
            musicId: music?.id,
            musicTitle: title,
            musicArtist: artist,
            musicVolume: kMusicVolume,
            keepSound: _keepSound,
          );
        }
      }
      if (_alsoStory) {
        await _addToStory(
          image: storyImage,
          video: storyVideo,
          thumb: storyThumb,
          seconds: storySecs,
        );
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

  /// The same photo or clip as a moment for 24 hours (a failure never undoes the post).
  Future<void> _addToStory({
    required String image,
    required String video,
    required String thumb,
    required int seconds,
  }) async {
    try {
      if (video.isNotEmpty && seconds > kMaxStorySeconds) {
        if (mounted) {
          showToast(
            context,
            'Posted. The video is longer than $kMaxStorySeconds s, so it was not added to your moments.',
          );
        }
        return;
      }
      final m = _music;
      await StoryService.instance.addStoryFromRefs(
        imageRef: image,
        videoRef: video,
        thumbRef: thumb,
        duration: seconds,
        // a song that is part of the video file is not played again over it
        musicId: _baked ? '' : (m?.id ?? ''),
        musicTitle: (m?.remote ?? false) && !_baked ? m!.title : '',
        musicArtist: (m?.remote ?? false) && !_baked ? m!.artist : '',
        musicVolume: kMusicVolume,
        keepSound: _keepSound,
      );
    } catch (e) {
      if (mounted) {
        showToast(
          context,
          'Posted, but not added to your moments. ${friendlyError(e)}',
        );
      }
    }
  }

  /// Saves the videos again where needed (one at a time), then sends everything up, three
  /// files at the same time.
  Future<List<PostItem>> _uploadAll(List<_Item> items) async {
    // 1) videos: only saved again (up to 1080p, or 720p when "Original quality" is off) when
    //    they were edited, when the switch is off or when they are bigger than the service
    //    accepts. The index of the video goes to the front so it starts at once for viewers;
    //    nothing is re-encoded for that.
    final ready = <int, _Ready>{};
    try {
      var n = 0;
      final videoCount = items.where((i) => i.video).length;
      for (var i = 0; i < items.length; i++) {
        final it = items[i];
        if (!it.video) continue;
        n++;
        final tag = videoCount > 1 ? ' $n of $videoCount' : '';
        ready[i] = await _prepareVideo(it, tag);
      }

      // 2) upload
      var total = 0;
      for (var i = 0; i < items.length; i++) {
        total += items[i].video
            ? await ready[i]!.file.length()
            : items[i].bytes;
      }
      _totalBytes = total;
      _clock
        ..reset()
        ..start();
      if (mounted) {
        setState(() {
          _stage = 'Uploading...';
          _progress = 0;
        });
      }
      final sent = List<double>.filled(items.length, 0);
      final sizes = [
        for (var i = 0; i < items.length; i++)
          items[i].video ? ready[i]!.file.lengthSync() : items[i].bytes,
      ];
      void report(int i, double p) {
        sent[i] = p;
        var done = 0.0;
        for (var k = 0; k < items.length; k++) {
          done += sent[k] * sizes[k];
        }
        _sentBytes = done.round();
        _onProgress(total == 0 ? 0 : done / total);
      }

      final out = List<PostItem?>.filled(items.length, null);
      var next = 0;
      Future<void> worker() async {
        while (true) {
          final i = next++;
          if (i >= items.length) return;
          final it = items[i];
          if (it.video) {
            final r = ready[i]!;
            final cover = await _coverFor(it);
            final media = await MediaServer.instance.uploadVideo(
              file: r.file,
              thumb: cover,
              onProgress: (p) => report(i, p),
            );
            if (cover != null && cover.path != it.thumb?.path) {
              cover.delete().ignore();
            }
            out[i] = PostItem(
              video: true,
              ref: media.ref,
              thumbRef: media.thumbRef,
              width: r.width,
              height: r.height,
              seconds: r.seconds ?? it.seconds,
              finish: it.finish,
            );
          } else {
            final media = await MediaServer.instance.uploadImage(
              it.file,
              onProgress: (p) => report(i, p),
            );
            out[i] = PostItem(
              video: false,
              ref: media.ref,
              width: it.width,
              height: it.height,
            );
          }
          report(i, 1);
        }
      }

      await Future.wait([
        for (var w = 0; w < math.min(3, items.length); w++) worker(),
      ]);
      return [for (final o in out) o!];
    } finally {
      for (final r in ready.values) {
        r.temp?.delete().ignore();
        r.merged?.delete().ignore();
      }
      VideoCompress.deleteAllCache();
    }
  }

  /// The cover of a video with its colour look and texts burned in, so grids and previews
  /// match what plays (the video file itself is not touched).
  Future<File?> _coverFor(_Item it) async {
    final t = it.thumb;
    final f = it.finish;
    if (t == null || f == null) return t;
    try {
      final l = f.look;
      final edits = l == null
          ? null
          : PhotoEdits(
              filter: l.filter,
              brightness: l.brightness,
              contrast: l.contrast,
              saturation: l.saturation,
            );
      // the cover is the first picture: only what is on screen then is burned in
      return await finishPhoto(t, edits, [
        for (final o in f.overlays)
          if (o.visibleAt(0)) o,
      ]);
    } catch (_) {
      return t;
    }
  }

  Future<_Ready> _prepareVideo(_Item it, String tag) async {
    var file = it.file;
    MediaInfo? info;
    if (_willShrink(it)) {
      if (mounted) {
        setState(() {
          _stage = 'Processing video$tag...';
          _progress = null;
        });
      }
      final sub = VideoCompress.compressProgress$.subscribe((p) {
        if (mounted) setState(() => _progress = (p / 100).clamp(0.0, 1.0));
      });
      final ve = it.videoEdits;
      final cut = ve != null && ve.trimmed;
      try {
        info = await VideoCompress.compressVideo(
          it.file.path,
          quality: VideoQuality.Res1920x1080Quality,
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
      file = shrunk;
    }
    // A hit song (Apple preview) is mixed into a clip on the phone: it replaces the video's
    // own sound and the clip is cut to the length of the preview.
    File? merged;
    int? cutSeconds;
    final song = _bakeTrack;
    if (song != null) {
      if (mounted) {
        setState(() {
          _stage = 'Adding the song...';
          _progress = null;
        });
      }
      try {
        final audio = await ItunesService.instance.downloadPreview(song);
        final m = await AudioMerger.merge(
          video: file,
          audio: audio,
          maxSeconds: kSongPreviewSeconds.toDouble(),
        );
        merged = m.file;
        file = m.file;
        cutSeconds = math.max(1, m.seconds.round());
        _baked = true;
      } catch (e) {
        _baked = false;
        if (mounted) {
          showToast(
            context,
            'The song could not be put into the video (${friendlyError(e)}). It plays next to the video instead.',
          );
        }
      }
    }
    if (mounted) {
      setState(() {
        _stage = 'Getting ready...';
        _progress = null;
      });
    }
    final fast = await Mp4FastStart.run(file);
    final temp = fast.path != file.path ? fast : null;
    // proportions: the picked file's (already turned upright); a saved copy keeps them
    var w = it.width;
    var h = it.height;
    if (w == 0 || h == 0) {
      w = info?.width ?? 0;
      h = info?.height ?? 0;
    }
    return _Ready(fast, temp, w, h, merged: merged, seconds: cutSeconds);
  }

  /// "31.2 of 74.0 MB  ·  2.8 MB/s"
  String get _uploadDetail {
    final p = _progress;
    if (p == null || _totalBytes <= 0 || _stage != 'Uploading...') return '';
    final sent = _sentBytes > 0 ? _sentBytes : (p * _totalBytes).round();
    final secs = _clock.elapsedMilliseconds / 1000;
    final speed = (secs >= 1 && sent > 0)
        ? '  \u00b7  ${(sent / secs / (1024 * 1024)).toStringAsFixed(1)} MB/s'
        : '';
    return '${_mb(sent)} of ${_mb(_totalBytes)}$speed';
  }

  static String _mb(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).round()} KB';

  // --------------------------------------------------------------------- build

  String get _title => _mode == 1 ? 'New clip' : 'New post';

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
            key: const ValueKey('createBack'),
            icon: Icon(
              _step == 0 ? Icons.close_rounded : Icons.arrow_back_rounded,
            ),
            onPressed: _busy
                ? null
                : () => _step == 0 ? Navigator.of(context).pop(false) : _go(0),
          ),
          title: Text(_title),
          actions: [
            if (_step == 0)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: TextButton(
                  key: const ValueKey('nextButton'),
                  onPressed: _hasMedia ? _next : null,
                  child: Text(
                    context.tr('Next'),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
          ],
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
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
            child: _frame(context),
          ),
        ),
        if (_mode == 0 && _hasMedia) _strip(context),
        if (_hasMedia) _toolbar(context) else _chooseButton(context),
        _modeTabs(context),
      ],
    );
  }

  Widget _chooseButton(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
    child: SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        key: const ValueKey('chooseMedia'),
        onPressed: _pick,
        icon: Icon(
          _mode == 0
              ? Icons.add_photo_alternate_rounded
              : Icons.video_call_rounded,
        ),
        label: Text(
          _mode == 0 ? 'Choose photos or videos' : 'Choose a video or photo',
        ),
      ),
    ),
  );

  /// The biggest frame with the post's proportions that fits the space. Besides the media it
  /// only holds the play / pause sign and the "2/5" counter.
  Widget _frame(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final a = _frameAspect;
        var w = c.maxWidth;
        var h = w / a;
        if (h > c.maxHeight) {
          h = c.maxHeight;
          w = h * a;
        }
        return Center(
          child: SizedBox(
            key: const ValueKey('previewFrame'),
            width: w,
            height: h,
            child: ClipRect(
              child: ColoredBox(
                color: const Color(0xFF0A0A0A),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _hasMedia ? _togglePreview : _pick,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _previewContent(context),
                      if (_mode == 0 && _items.length > 1)
                        Positioned(
                          right: 10,
                          top: 10,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${_sel + 1}/${_items.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      if (_hasMedia && _canPlay) ...[
                        if (_previewPaused)
                          const IgnorePointer(
                            child: Center(
                              child: Icon(
                                Icons.play_arrow_rounded,
                                size: 84,
                                color: Colors.white,
                                shadows: [
                                  Shadow(blurRadius: 16, color: Colors.black54),
                                ],
                              ),
                            ),
                          ),
                        Positioned(
                          left: 10,
                          bottom: 10,
                          child: GestureDetector(
                            key: const ValueKey('previewPlayPause'),
                            behavior: HitTestBehavior.opaque,
                            onTap: _togglePreview,
                            child: Container(
                              width: 42,
                              height: 42,
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                _previewPaused
                                    ? Icons.play_arrow_rounded
                                    : Icons.pause_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _previewContent(BuildContext context) {
    final it = _active;
    if (it == null) {
      return Center(
        child: Icon(
          _mode == 0 ? Icons.image_outlined : Icons.smart_display_outlined,
          size: 64,
          color: Colors.white24,
        ),
      );
    }
    if (!it.video) {
      return SizedBox.expand(
        child: Image.file(
          it.file,
          fit: BoxFit.contain,
          cacheWidth: 1600,
          filterQuality: FilterQuality.medium,
        ),
      );
    }
    final c = _preview;
    if (c != null && c.value.isInitialized && identical(_previewFor, it)) {
      return SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: c.value.size.width,
            height: c.value.size.height,
            child: FinishedMedia(
              finish: it.finish,
              player: c,
              child: VideoPlayer(c),
            ),
          ),
        ),
      );
    }
    final t = it.thumb;
    return t == null
        ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
        : SizedBox.expand(child: Image.file(t, fit: BoxFit.contain));
  }

  /// The chosen photos and videos, like the strip under the picture on Instagram.
  Widget _strip(BuildContext context) {
    return SizedBox(
      height: 78,
      child: ListView(
        key: const ValueKey('mediaStrip'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        children: [
          for (var i = 0; i < _items.length; i++) _tile(context, i),
          if (_items.length < kMaxPostItems)
            GestureDetector(
              key: const ValueKey('addMore'),
              onTap: _pick,
              child: Container(
                width: 64,
                height: 64,
                margin: const EdgeInsets.only(left: 2),
                decoration: BoxDecoration(
                  color: context.cardHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.add_rounded, size: 30),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, int i) {
    final it = _items[i];
    final selected = i == _sel;
    final cover = it.video ? it.thumb : it.file;
    return GestureDetector(
      key: ValueKey('tile$i'),
      onTap: () => _select(i),
      child: Container(
        width: 64,
        height: 64,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppTheme.volt : Colors.transparent,
            width: 2.5,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (cover != null)
                Image.file(cover, fit: BoxFit.cover, cacheWidth: 200)
              else
                ColoredBox(color: context.cardHigh),
              if (!selected) const ColoredBox(color: Color(0x55000000)),
              if (it.video)
                const Center(
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              Positioned(
                right: 0,
                top: 0,
                child: GestureDetector(
                  key: ValueKey('remove$i'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _remove(i),
                  child: Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: const BoxDecoration(
                        color: Colors.black87,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        size: 11,
                        color: Colors.white,
                      ),
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

  /// Edit, Music and (in Clips) Change.
  Widget _toolbar(BuildContext context) {
    final m = _music;
    Widget tool(Key key, IconData icon, String label, VoidCallback? onTap) =>
        Expanded(
          child: InkWell(
            key: key,
            borderRadius: BorderRadius.circular(14),
            onTap: _busy ? null : onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 24),
                  const SizedBox(height: 4),
                  Text(
                    context.tr(label),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
      child: Row(
        children: [
          tool(const ValueKey('editButton'), Icons.tune_rounded, 'Edit', _edit),
          tool(
            const ValueKey('audioBar'),
            Icons.music_note_rounded,
            m == null ? (_photoClip ? 'Add audio (needed)' : 'Audio') : m.title,
            _chooseMusic,
          ),
          if (_mode == 1)
            tool(
              const ValueKey('changeButton'),
              Icons.swap_horiz_rounded,
              'Change',
              _pick,
            ),
        ],
      ),
    );
  }

  /// Post | Clips, as plain words with an underline (like the bottom of Instagram's picker).
  Widget _modeTabs(BuildContext context) {
    Widget tab(int i, String label) {
      final on = _mode == i;
      return Expanded(
        child: GestureDetector(
          key: ValueKey('mode$i'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _setMode(i),
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Column(
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w900,
                    color: on ? null : context.muted,
                  ),
                ),
                const SizedBox(height: 6),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  height: 3,
                  width: on ? 34 : 0,
                  decoration: BoxDecoration(
                    color: AppTheme.volt,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: context.hairline)),
        ),
        child: Row(children: [tab(0, 'Post'), tab(1, 'Clips')]),
      ),
    );
  }

  // ---- step 2: details ----

  Widget _detailsStep(BuildContext context) {
    final first = _chosen.isEmpty ? null : _chosen.first;
    final cover = first == null
        ? null
        : (first.video ? first.thumb : first.file);
    final needsPhoto = _mode == 0 && !_hasPhoto;
    final screen = MediaQuery.sizeOf(context);
    // the cover takes at least half of the screen
    final coverHeight = math.max(300.0, screen.height * 0.5);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 20),
            children: [
              SizedBox(
                key: const ValueKey('detailsThumb'),
                height: coverHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: Colors.black,
                      child: cover == null
                          ? const SizedBox.expand()
                          : Image.file(
                              cover,
                              key: ValueKey('cover$_coverVer'),
                              fit: BoxFit.contain,
                              cacheWidth: 1200,
                            ),
                    ),
                    if (_chosen.length > 1)
                      Positioned(
                        left: 12,
                        top: 12,
                        child: _coverPill(
                          Icons.collections_rounded,
                          '${_chosen.length} items',
                        ),
                      ),
                    if (first != null && first.video)
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: GestureDetector(
                          key: const ValueKey('changeCover'),
                          onTap: _busy ? null : _pickCover,
                          child: _coverPill(
                            Icons.photo_size_select_actual_rounded,
                            'Change cover',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: TextField(
                  key: const ValueKey('captionField'),
                  controller: _caption,
                  enabled: !_busy,
                  maxLines: 4,
                  minLines: 2,
                  maxLength: 200,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: 'Write a caption...',
                    helperText: _caption.text.trim().isEmpty
                        ? 'A caption is required'
                        : null,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                  ),
                ),
              ),
              Divider(height: 1, color: context.hairline),
              ListTile(
                key: const ValueKey('audienceRow'),
                leading: Icon(_audienceIcon(_audience)),
                title: Text(
                  context.tr('Audience'),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(context.tr(_audienceName(_audience))),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _busy ? null : _chooseAudience,
              ),
              SwitchListTile(
                key: const ValueKey('storyRow'),
                value: _alsoStory,
                onChanged: _busy ? null : (v) => setState(() => _alsoStory = v),
                activeTrackColor: AppTheme.volt,
                secondary: const Icon(Icons.auto_awesome_rounded),
                title: Text(
                  context.tr('Also share to your moments'),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: const Text('It stays there for 24 hours.'),
              ),
              if (_photoClip)
                ListTile(
                  key: const ValueKey('clipLengthRow'),
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text(
                    'Plays for $kPhotoClipSeconds seconds',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ExpansionTile(
                key: const ValueKey('advancedRow'),
                leading: const Icon(Icons.tune_rounded),
                title: Text(
                  context.tr('Advanced settings'),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                shape: const Border(),
                collapsedShape: const Border(),
                children: [
                  SwitchListTile(
                    key: const ValueKey('hideLikesRow'),
                    value: _hideLikes,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _hideLikes = v),
                    activeTrackColor: AppTheme.volt,
                    title: Text(context.tr('Hide like count')),
                    subtitle: const Text('Only you see the number.'),
                  ),
                  SwitchListTile(
                    key: const ValueKey('hideCommentsRow'),
                    value: _hideComments,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _hideComments = v),
                    activeTrackColor: AppTheme.volt,
                    title: Text(context.tr('Hide comment count')),
                  ),
                  SwitchListTile(
                    key: const ValueKey('hideSharesRow'),
                    value: _hideShares,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _hideShares = v),
                    activeTrackColor: AppTheme.volt,
                    title: Text(context.tr('Hide share count')),
                  ),
                ],
              ),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: Text(
                  _summary(),
                  style: TextStyle(
                    color: context.muted,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
              if (needsPhoto)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('A post needs at least one photo.'),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
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
                  child: FilledButton(
                    key: const ValueKey('shareButton'),
                    onPressed: _canShare ? _share : null,
                    child: _busy
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: AppTheme.ink,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  _progress == null
                                      ? _stage
                                      : '$_stage ${(_progress! * 100).round()}%',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          )
                        : Text(context.tr('Share')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _coverPill(IconData icon, String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: Colors.white),
        const SizedBox(width: 6),
        Text(
          context.tr(text),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 13,
          ),
        ),
      ],
    ),
  );

  static IconData _audienceIcon(String a) => a == kAudienceMe
      ? Icons.lock_outline_rounded
      : a == kAudienceFollowers
      ? Icons.group_outlined
      : Icons.public_rounded;

  static String _audienceName(String a) => a == kAudienceMe
      ? 'Only me'
      : a == kAudienceFollowers
      ? 'Followers'
      : 'Everyone';

  Future<void> _chooseAudience() async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final a in const [
              kAudienceEveryone,
              kAudienceFollowers,
              kAudienceMe,
            ])
              ListTile(
                key: ValueKey('audience_$a'),
                leading: Icon(_audienceIcon(a)),
                title: Text(
                  _audienceName(a),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(
                  a == kAudienceEveryone
                      ? 'Anyone on InstantGram'
                      : a == kAudienceFollowers
                      ? 'Only people who follow you'
                      : 'Only you can see it',
                ),
                trailing: _audience == a
                    ? const Icon(Icons.check_rounded, color: AppTheme.volt)
                    : null,
                onTap: () => Navigator.pop(ctx, a),
              ),
          ],
        ),
      ),
    );
    if (pick != null && mounted) setState(() => _audience = pick);
  }

  /// Choose the picture that stands for the clip: slide to a moment of the video.
  Future<void> _pickCover() async {
    final it = _first;
    if (it == null || !it.video || _busy) return;
    final total = math.max(1, it.secondsFull > 0 ? it.secondsFull : it.seconds);
    final File? f = await showModalBottomSheet<File>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CoverSheet(path: it.original.path, seconds: total),
    );
    if (f == null || !mounted) return;
    setState(() {
      it.thumb = f;
      _coverVer++;
    });
  }

  String _summary() {
    final list = _chosen;
    final photos = list.where((i) => !i.video).length;
    final videos = list.length - photos;
    final bytes = list.fold<int>(0, (s, i) => s + i.bytes);
    final parts = <String>[
      if (photos > 0) '$photos photo${photos == 1 ? '' : 's'}',
      if (videos > 0) '$videos video${videos == 1 ? '' : 's'}',
      _mb(bytes),
    ];
    if (list.length == 1) {
      final it = list.first;
      if (it.video) {
        final e = it.videoEdits;
        return [
          formatDuration(it.seconds),
          _mb(it.bytes),
          if (e != null && e.trimmed) 'Trimmed',
          if (e != null && e.mute) 'No sound',
        ].join('  \u00b7  ');
      }
      return '${it.edits != null || it.overlays.isNotEmpty ? 'Edited photo' : 'Photo'}  \u00b7  ${_mb(it.bytes)}';
    }
    return parts.join('  \u00b7  ');
  }
}

/// A picture of the video at [ms]. Every call writes a new file, so a changed cover is never
/// shown from the picture cache.
Future<File> frameAt(String videoPath, int ms) async {
  final f = await VideoCompress.getFileThumbnail(
    videoPath,
    quality: 85,
    position: ms,
  );
  final copy = File(
    '${Directory.systemTemp.path}/instantgram_cover_${DateTime.now().microsecondsSinceEpoch}.jpg',
  );
  return f.copy(copy.path);
}

/// Slide through the video and use the frame you like as the cover.
class _CoverSheet extends StatefulWidget {
  const _CoverSheet({required this.path, required this.seconds});
  final String path;
  final int seconds;

  @override
  State<_CoverSheet> createState() => _CoverSheetState();
}

class _CoverSheetState extends State<_CoverSheet> {
  double _t = 0;
  File? _frame;
  bool _loading = false;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final gen = ++_gen;
    setState(() => _loading = true);
    try {
      final f = await frameAt(widget.path, (_t * 1000).round());
      if (!mounted || gen != _gen) return;
      setState(() => _frame = f);
    } catch (_) {
      // keep the previous frame
    } finally {
      if (mounted && gen == _gen) setState(() => _loading = false);
    }
  }

  /// Any photo from the phone as the cover (saved as a 1280 px JPEG).
  Future<void> _fromGallery() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (x == null || !mounted) return;
      setState(() => _loading = true);
      final proxy = await PhotoEditor.makeProxy(File(x.path));
      if (mounted) Navigator.pop(context, proxy.file);
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
        showToast(context, 'Could not use this photo as a cover.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: h * 0.45,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: ColoredBox(
                  color: Colors.black,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_frame != null)
                        Image.file(
                          _frame!,
                          key: ValueKey('f${_frame!.path}$_gen'),
                          fit: BoxFit.contain,
                        ),
                      if (_loading)
                        const Center(child: CircularProgressIndicator()),
                    ],
                  ),
                ),
              ),
            ),
            Slider(
              key: const ValueKey('coverSlider'),
              value: _t,
              max: widget.seconds.toDouble(),
              onChanged: (v) => setState(() => _t = v),
              onChangeEnd: (_) => _load(),
            ),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('coverFromGallery'),
                onPressed: _fromGallery,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Choose from gallery'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('useCover'),
                onPressed: _frame == null
                    ? null
                    : () => Navigator.pop(context, _frame),
                child: const Text('Use this cover'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
