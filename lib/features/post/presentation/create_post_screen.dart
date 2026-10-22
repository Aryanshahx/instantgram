import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/services/media_service.dart';
import '../../../core/services/music_player.dart';
import '../../../core/services/spam_guard.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/widgets/face_effects.dart';
import '../../../shared/widgets/ig_buttons.dart';
import '../../../shared/widgets/media_links.dart';
import '../../../shared/widgets/media_view.dart';
import '../../editor/cover_render.dart';
import '../../editor/edit_models.dart';
import '../../editor/filters.dart';
import '../../editor/video_frames.dart';
import '../../profile/data/user_repository.dart';
import '../../stories/data/highlight_repository.dart';
import '../data/post_repository.dart';
import '../data/upload_queue.dart';
import 'create_sheet.dart' show ComposeReply;
import 'my_post_picker.dart' show ReplyStickerChip;
import '../../../shared/widgets/hi_text_check.dart';
import '../../../shared/widgets/skeleton.dart';

export '../../editor/edit_models.dart' show ComposeMode, EditedMedia;
export '../../../shared/widgets/media_view.dart' show PageDots;

/// Share screen (after the editor): big preview, caption, cover,
/// audience, "also share to moment" and hidden counts.
class CreatePostScreen extends StatefulWidget {
  const CreatePostScreen({
    super.key,
    required this.items,
    required this.mode,
    this.audio,
  });

  final List<EditedMedia> items;
  final ComposeMode mode;

  /// Music picked in the editor (v0.16: also moments).
  final PickedAudio? audio;

  /// Tests: your highlights (else Firestore).
  @visibleForTesting
  static Stream<List<Highlight>> Function()? debugHighlights;

  @override
  State<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends State<CreatePostScreen> {
  final _caption = TextEditingController();
  final _pages = PageController();
  int _page = 0;

  String _audience = Audience.everyone;
  bool _alsoMoment = false;
  bool _hideLikes = false;
  bool _hideComments = false;
  bool _hideReposts = false;
  bool _hideShares = false;

  /// v0.16: post / clip only on your profile (not in feeds).
  bool _profileOnly = false;

  /// v0.16: moments straight into a highlight ('' = normal moment).
  String _hlId = '';
  String _hlTitle = '';

  /// Clip cover chosen by the user (already filtered if from the video).
  File? _cover;
  bool _coverFromGallery = false;
  bool _makingCover = false;

  double? _progress; // null = not uploading
  String? _error;

  /// v0.9: this clip / post answers a comment (sticker on it).
  ReplyRef? _reply = ComposeReply.pending;

  bool get _isClip => widget.mode == ComposeMode.clip;
  bool get _isStory => widget.mode == ComposeMode.story;

  /// Clip whose first item is a video -> it gets a cover.
  bool get _hasCover => _isClip && widget.items.first.isVideo;

  /// One-video clip -> big cover preview (else a swipeable preview).
  bool get _singleVideoClip => _hasCover && widget.items.length == 1;

  bool _musicPlaying = false;
  static const String _kMusic = 'share-preview';

  @override
  void dispose() {
    MusicPlayer.instance.stop(_kMusic);
    _caption.dispose();
    _pages.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- cover

  Future<void> _coverFromVideo() async {
    final item = widget.items.first;
    final ms = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CoverPickerScreen(item: item),
      ),
    );
    if (ms == null || !mounted) return;
    setState(() => _makingCover = true);
    final f = await VideoFrames.file(item.file.path, ms, maxWidth: 1080);
    // v0.0.2: the cover has the filter AND the texts / stickers
    final baked = f == null
        ? null
        : await bakeCover(f, item.edits, ms: ms, aspect: item.aspectRatio);
    if (!mounted) return;
    setState(() {
      _makingCover = false;
      if (baked != null) {
        _cover = baked;
        _coverFromGallery = false;
      }
    });
    if (baked == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not take a frame from this video')),
      );
    }
  }

  Future<void> _coverFromPhotos() async {
    try {
      final f = await MediaService.instance.pickGalleryImage();
      if (f == null || !mounted) return;
      setState(() {
        _cover = f;
        _coverFromGallery = true;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  // ---------------------------------------------------------------- share

  PostOptions get _options => PostOptions(
    audience: _audience,
    alsoMoment: _alsoMoment,
    hideLikes: _hideLikes,
    hideComments: _hideComments,
    hideReposts: _hideReposts,
    hideShares: _hideShares,
    profileOnly: _profileOnly,
  );

  PostOptions get _momentOptions => PostOptions(
    audience: _audience,
    highlightId: _hlId,
    highlightTitle: _hlTitle,
  );

  Future<void> _share() async {
    FocusScope.of(context).unfocus();
    // v0.18 Hyper Intelligence: no strong abuse in the caption
    if (!_isStory && !await hiTextOk(context, [_caption.text])) return;
    if (!mounted) return;
    // v0.20 Hyper Intelligence: strikes + new-account limit
    final stop = await postingStopReason(isStory: _isStory);
    if (!mounted) return;
    if (stop != null) {
      setState(() => _error = stop);
      return;
    }
    setState(() {
      _progress = 0;
      _error = null;
    });
    void onProgress(double v) {
      if (mounted) setState(() => _progress = v.clamp(0, 1));
    }

    try {
      final items = widget.items;
      MusicPlayer.instance.stop(_kMusic);
      // v0.8: upload goes on in the background (bar in Discover +
      // notification); you can use the app right away
      final queued = <QueuedMedia>[];
      for (var i = 0; i < items.length; i++) {
        final m = items[i];
        File? thumb;
        if (!_isStory && m.isVideo && m.preview != null) {
          thumb = await bakeCover(
            m.preview!,
            m.edits,
            ms: m.edits.trimStartMs,
            aspect: m.aspectRatio,
          );
        }
        onProgress((i + 1) / items.length);
        queued.add(
          QueuedMedia(
            path: m.file.path,
            isVideo: m.isVideo,
            aspectRatio: m.aspectRatio,
            edits: m.edits,
            durationMs: m.durationMs,
            thumbPath: thumb?.path,
            links: _isStory ? const [] : m.links,
          ),
        );
      }
      UploadQueue.instance.add(
        kind: _isStory
            ? UploadTask.moment
            : _isClip
            ? UploadTask.clip
            : UploadTask.post,
        items: queued,
        caption: _isStory ? '' : _caption.text,
        options: _isStory ? _momentOptions : _options,
        coverPath: !_isStory && _hasCover ? _cover?.path : null,
        audioPath: widget.audio == null || widget.audio!.isOnline
            ? null
            : widget.audio!.file.path,
        audioName: widget.audio?.name ?? '',
        // music update: library / AI / someone's song (no upload)
        audioUrl: widget.audio?.url ?? '',
        musicId: widget.audio?.musicId ?? '',
        audioStartMs: widget.audio?.startMs ?? 0,
        audioDurationMs: widget.audio?.durationMs ?? 0,
        replyTo: _isStory ? null : _reply,
      );
      if (!_isStory) SpamGuard.instance.recordPost();
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).popUntil((r) => r.isFirst);
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Sharing in the background… you can keep using the app',
          ),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = friendlyError(e);
        });
      }
    }
  }

  // ---------------------------------------------------------------- UI

  Future<void> _pickAudience() async {
    final a = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                'Audience',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
            for (final opt in Audience.all)
              ListTile(
                leading: Icon(_audienceIcon(opt), color: AppColors.lime),
                title: Text(
                  Audience.label(opt),
                  style: const TextStyle(
                    fontFamily: AppTheme.fontFamily,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Text(
                  _audienceHint(opt),
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
                trailing: opt == _audience
                    ? const Icon(Icons.check_circle, color: AppColors.lime)
                    : null,
                onTap: () => Navigator.pop(ctx, opt),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (a != null) setState(() => _audience = a);
  }

  static IconData _audienceIcon(String a) => switch (a) {
    Audience.followers => Icons.people_outline,
    Audience.onlyMe => Icons.lock_outline,
    _ => Icons.public,
  };

  static String _audienceHint(String a) => switch (a) {
    Audience.followers => 'Only people who follow you',
    Audience.onlyMe => 'Only you can see it',
    _ => 'Anyone on InstantGram',
  };

  Widget _previewItem(EditedMedia m, {BoxFit fit = BoxFit.contain}) {
    if (!m.isVideo) {
      final photo = Image.file(m.file, fit: fit, gaplessPlayback: true);
      if (m.links.isEmpty) return photo;
      return Stack(
        fit: StackFit.expand,
        children: [
          photo,
          IgnorePointer(
            child: MediaLinksLayer(
              links: m.links,
              aspect: m.aspectRatio,
              fit: fit,
            ),
          ),
        ],
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        // v0.0.2: exactly as posted: real shape, filter, texts, stickers
        if (m.preview != null)
          Center(
            child: EditedFrame(
              key: const ValueKey('share-edited-frame'),
              frame: FileImage(m.preview!),
              edits: m.edits,
              aspect: m.aspectRatio,
              ms: m.edits.trimStartMs,
              links: m.links,
            ),
          )
        else
          const ColoredBox(color: AppColors.surface),
        Center(
          child: Icon(
            Icons.play_circle_fill,
            size: 56,
            color: Colors.white.withValues(alpha: 0.85),
          ),
        ),
        Positioned(
          left: 10,
          bottom: 10,
          child: MediaPill(
            icon: m.edits.muted ? Icons.volume_off : Icons.videocam,
            text: durationLabel(m.durationMs),
          ),
        ),
      ],
    );
  }

  Widget _preview(double height) {
    final items = widget.items;
    if (_singleVideoClip) {
      final v = items.first;
      final Widget img;
      if (_cover != null) {
        // v0.0.2: a cover from the video already has texts / stickers
        img = ColoredBox(
          color: Colors.black,
          child: Image.file(
            _cover!,
            fit: _coverFromGallery ? BoxFit.cover : BoxFit.contain,
            gaplessPlayback: true,
          ),
        );
      } else if (v.preview != null) {
        img = ColoredBox(
          color: Colors.black,
          child: Center(
            child: EditedFrame(
              key: const ValueKey('share-edited-frame'),
              frame: FileImage(v.preview!),
              edits: v.edits,
              aspect: v.aspectRatio,
              ms: v.edits.trimStartMs,
              links: v.links,
            ),
          ),
        );
      } else {
        img = const ColoredBox(
          color: AppColors.surface,
          child: Center(child: Icon(Icons.movie_creation_outlined, size: 56)),
        );
      }
      return Center(
        child: SizedBox(
          height: height,
          child: AspectRatio(
            aspectRatio: v.aspectRatio.clamp(0.5, 1.0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  img,
                  if (_makingCover)
                    const ColoredBox(
                      color: Color(0x88000000),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  Positioned(
                    left: 10,
                    top: 10,
                    child: MediaPill(
                      icon: Icons.image_outlined,
                      text: _cover == null
                          ? 'Cover'
                          : (_coverFromGallery
                                ? 'Your cover'
                                : 'Cover from video'),
                    ),
                  ),
                  Positioned(
                    right: 10,
                    top: 10,
                    child: MediaPill(
                      icon: v.edits.muted ? Icons.volume_off : Icons.videocam,
                      text: durationLabel(v.durationMs),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: height,
      child: Stack(
        children: [
          PageView.builder(
            controller: _pages,
            itemCount: items.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: ColoredBox(
                  color: Colors.black,
                  child: _previewItem(items[i]),
                ),
              ),
            ),
          ),
          if (items.length > 1) ...[
            Positioned(
              right: 28,
              top: 12,
              child: MediaPill(text: '${_page + 1}/${items.length}'),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 10,
              child: PageDots(count: items.length, index: _page),
            ),
          ],
        ],
      ),
    );
  }

  Widget _musicRow(PickedAudio a) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Container(
        key: const ValueKey('share-music'),
        padding: const EdgeInsets.only(left: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            const Icon(Icons.music_note, color: AppColors.lime, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                a.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: _musicPlaying ? 'Pause' : 'Play',
              onPressed: () {
                setState(() => _musicPlaying = !_musicPlaying);
                _musicPlaying
                    ? MusicPlayer.instance.play(
                        _kMusic,
                        a.source,
                        startMs: a.startMs,
                      )
                    : MusicPlayer.instance.stop(_kMusic);
              },
              icon: Icon(_musicPlaying ? Icons.pause : Icons.play_arrow),
            ),
          ],
        ),
      ),
    );
  }

  Widget _switch(
    String title,
    bool value,
    ValueChanged<bool> onChanged, {
    String? subtitle,
    IconData? icon,
  }) {
    return SwitchListTile(
      value: value,
      onChanged: _progress != null ? null : onChanged,
      activeThumbColor: Colors.black,
      activeTrackColor: AppColors.lime,
      dense: true,
      secondary: icon == null ? null : Icon(icon, size: 22),
      title: Text(
        title,
        style: const TextStyle(
          fontFamily: AppTheme.fontFamily,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
    );
  }

  // ------------------------------------------------- v0.16: highlight only

  Future<void> _pickHighlight() async {
    final stream =
        (CreatePostScreen.debugHighlights ??
        () => HighlightRepository.instance.watch(
          UserRepository.instance.myUid,
        ))();
    final res = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _HighlightChooser(stream: stream),
    );
    if (res == null || !mounted) return;
    setState(() {
      _hlId = res.$1;
      _hlTitle = res.$2;
    });
  }

  Widget _shareTo() {
    Widget choice(
      String key,
      IconData icon,
      String title,
      String sub,
      bool on,
      VoidCallback onTap,
    ) => ListTile(
      key: ValueKey(key),
      dense: true,
      enabled: _progress == null,
      leading: Icon(icon, size: 22, color: on ? AppColors.lime : null),
      title: Text(
        title,
        style: const TextStyle(
          fontFamily: AppTheme.fontFamily,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        sub,
        style: const TextStyle(color: AppColors.textSecondary),
      ),
      trailing: Icon(
        on ? Icons.radio_button_checked : Icons.radio_button_off,
        color: on ? AppColors.lime : AppColors.textHint,
      ),
      onTap: onTap,
    );
    return _card([
      choice(
        'share-to-moment',
        Icons.amp_stories_outlined,
        'Your moment',
        'Shows for 24 hours',
        _hlId.isEmpty,
        () => setState(() {
          _hlId = '';
          _hlTitle = '';
        }),
      ),
      choice(
        'share-to-highlight',
        Icons.bookmark_border,
        _hlId.isEmpty ? 'Highlight only' : 'Highlight: $_hlTitle',
        _hlId.isEmpty
            ? 'Only on your profile highlights, not as a moment'
            : 'Tap to choose another highlight',
        _hlId.isNotEmpty,
        _pickHighlight,
      ),
    ]);
  }

  // A Material (not a coloured box) so the list rows show their taps.
  Widget _card(List<Widget> children) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final uploading = _progress != null;
    final screenH = MediaQuery.of(context).size.height;
    final previewH = (screenH * 0.5).clamp(260.0, 640.0);
    final title = _isStory
        ? (widget.items.length > 1
              ? 'New moments (${widget.items.length})'
              : 'New moment')
        : _isClip
        ? 'New clip'
        : 'New post';

    return PopScope(
      canPop: !uploading,
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(top: 4, bottom: 16),
                children: [
                  _preview(previewH),
                  if (widget.audio != null) _musicRow(widget.audio!),
                  if (_hasCover) ...[
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: IgOutlineButton(
                              key: const ValueKey('cover-video'),
                              label: 'Choose from video',
                              icon: Icons.movie_filter_outlined,
                              height: 40,
                              onPressed: uploading || _makingCover
                                  ? null
                                  : _coverFromVideo,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: IgOutlineButton(
                              key: const ValueKey('cover-gallery'),
                              label: 'Add thumbnail',
                              icon: Icons.add_photo_alternate_outlined,
                              height: 40,
                              onPressed: uploading ? null : _coverFromPhotos,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (!_isStory && _reply != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 8, 10),
                      child: Row(
                        children: [
                          Flexible(child: ReplyStickerChip(reply: _reply!)),
                          IconButton(
                            key: const ValueKey('reply-sticker-remove'),
                            tooltip: 'Remove',
                            onPressed: uploading
                                ? null
                                : () => setState(() => _reply = null),
                            icon: const Icon(Icons.close, size: 18),
                          ),
                        ],
                      ),
                    ),
                  if (!_isStory)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: _caption,
                        enabled: !uploading,
                        maxLines: 4,
                        minLines: 2,
                        maxLength: 2200,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          hintText: 'Write a caption… #hashtags',
                          hintStyle: const TextStyle(color: AppColors.textHint),
                          filled: true,
                          fillColor: AppColors.surface,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide: const BorderSide(
                              color: AppColors.border,
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide: const BorderSide(
                              color: AppColors.border,
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide: const BorderSide(color: AppColors.lime),
                          ),
                        ),
                      ),
                    ),
                  if (_isStory) _shareTo(),
                  if (!(_isStory && _hlId.isNotEmpty))
                    _card([
                      ListTile(
                        key: const ValueKey('audience'),
                        dense: true,
                        enabled: !uploading,
                        leading: Icon(_audienceIcon(_audience), size: 22),
                        title: const Text(
                          'Audience',
                          style: TextStyle(
                            fontFamily: AppTheme.fontFamily,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              Audience.label(_audience),
                              style: const TextStyle(
                                color: AppColors.lime,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                        onTap: _pickAudience,
                      ),
                      if (!_isStory)
                        _switch(
                          'Also share to your moment',
                          _alsoMoment,
                          (v) => setState(() => _alsoMoment = v),
                          icon: Icons.add_circle_outline,
                          subtitle: 'Shows for 24 hours',
                        ),
                      if (!_isStory)
                        _switch(
                          'Only on your profile',
                          _profileOnly,
                          (v) => setState(() => _profileOnly = v),
                          icon: Icons.grid_on,
                          subtitle: 'Not shown in feeds, Explore or Clips',
                        ),
                    ]),
                  if (!_isStory) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(28, 12, 16, 2),
                      child: Text(
                        'HIDE COUNTS',
                        style: TextStyle(
                          fontSize: 12,
                          letterSpacing: 1,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                    _card([
                      _switch(
                        'Hide like count',
                        _hideLikes,
                        (v) => setState(() => _hideLikes = v),
                        icon: Icons.favorite_border,
                      ),
                      _switch(
                        'Hide comment count',
                        _hideComments,
                        (v) => setState(() => _hideComments = v),
                        icon: Icons.chat_bubble_outline,
                      ),
                      _switch(
                        'Hide repost count',
                        _hideReposts,
                        (v) => setState(() => _hideReposts = v),
                        icon: Icons.repeat,
                      ),
                      _switch(
                        'Hide share count',
                        _hideShares,
                        (v) => setState(() => _hideShares = v),
                        icon: Icons.send_outlined,
                      ),
                    ]),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(28, 4, 28, 0),
                      child: Text(
                        'Only you will see hidden counts.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: AppColors.like),
                      ),
                    ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                child: uploading
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: LinearProgressIndicator(
                              value: _progress! >= 1 ? null : _progress,
                              minHeight: 8,
                              backgroundColor: AppColors.border,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _progress! >= 1
                                ? 'Finishing…'
                                : 'Uploading ${(_progress! * 100).round()}%',
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      )
                    : IgPrimaryButton(
                        key: const ValueKey('share'),
                        label: _isStory ? 'Share moment' : 'Share',
                        height: 50,
                        onPressed: _share,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pick a cover frame from the video (returns the time in ms).
/// v0.17: a row of frames from the video - tap one.
/// v0.19: more frames (30) + a slider for any exact moment.
class CoverPickerScreen extends StatefulWidget {
  const CoverPickerScreen({super.key, required this.item});
  final EditedMedia item;

  /// How many frames are shown.
  static const int frameCount = 30;

  /// Tests: makes a frame picture without the video plugin.
  static Future<Uint8List?> Function(String path, int ms)? debugFrame;

  /// Tests: no video player.
  static bool debugNoVideo = false;

  /// Times (ms) of [count] frames spread over start..end.
  static List<int> frameTimes(int start, int end, [int count = frameCount]) {
    if (end <= start) return [start];
    final last = math.max(start, end - 100); // the very end is often black
    if (count <= 1 || last == start) return [start];
    return [
      for (var i = 0; i < count; i++)
        start + ((last - start) * i / (count - 1)).round(),
    ];
  }

  @override
  State<CoverPickerScreen> createState() => _CoverPickerScreenState();
}

class _CoverPickerScreenState extends State<CoverPickerScreen> {
  VideoPlayerController? _c;
  bool _videoReady = false;
  List<int> _times = const [];
  final Map<int, Uint8List?> _thumbs = {};
  int _selected = 0;
  bool _disposed = false;
  final ScrollController _strip = ScrollController();

  /// v0.19: the cover time (any ms from the slider, or a frame's time).
  int _coverMs = 0;

  int get _ms => _times.isEmpty ? 0 : _coverMs;

  double get _tileW {
    final ar = widget.item.aspectRatio.clamp(0.5, 1.2).toDouble();
    // 104 high row: 2.5 border + 2 padding on each side, 3 margin
    return (104 - 9) * ar + 9 + 6;
  }

  /// Frame closest to [ms].
  int _nearest(int ms) {
    var best = 0;
    for (var i = 1; i < _times.length; i++) {
      if ((_times[i] - ms).abs() < (_times[best] - ms).abs()) best = i;
    }
    return best;
  }

  /// Keeps the chosen frame in the middle of the row.
  void _centerStrip() {
    if (!_strip.hasClients) return;
    final pos = _strip.position;
    final x = (_selected * _tileW - (pos.viewportDimension - _tileW) / 2).clamp(
      0.0,
      pos.maxScrollExtent,
    );
    _strip.jumpTo(x);
  }

  int _lastSeek = 0;

  void _slide(double v) {
    setState(() {
      _coverMs = v.round();
      _selected = _nearest(_coverMs);
    });
    _centerStrip();
    // not every pixel: phones get slow with too many seeks
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSeek > 80) {
      _lastSeek = now;
      _seek();
    }
  }

  void _seek() {
    final c = _c;
    if (c != null && _videoReady) c.seekTo(Duration(milliseconds: _ms));
  }

  @override
  void initState() {
    super.initState();
    final dur = widget.item.durationMs;
    if (dur > 0) _setRange(dur);
    if (CoverPickerScreen.debugNoVideo) return;
    final c = VideoPlayerController.file(widget.item.file);
    _c = c;
    c
        .initialize()
        .then((_) async {
          if (!mounted) return;
          if (_times.isEmpty) _setRange(c.value.duration.inMilliseconds);
          await c.setVolume(0);
          await c.seekTo(Duration(milliseconds: _ms));
          if (mounted) setState(() => _videoReady = true);
        })
        .catchError((Object _) {
          if (mounted) setState(() => _videoReady = false);
        });
  }

  /// Frames inside the trimmed part of the video.
  void _setRange(int total) {
    if (total <= 0) return;
    final e = widget.item.edits;
    final start = e.trimStartMs.clamp(0, total);
    final end = (e.trimEndMs > 0 ? e.trimEndMs : total).clamp(start, total);
    setState(() {
      _times = CoverPickerScreen.frameTimes(start, end);
      _selected = 0;
      _coverMs = _times.first;
    });
    unawaited(_loadThumbs());
  }

  /// One by one (phones get slow when many frames are made at once).
  Future<void> _loadThumbs() async {
    final times = _times;
    for (var i = 0; i < times.length; i++) {
      if (_disposed || times != _times) return;
      final f = CoverPickerScreen.debugFrame ?? _frame;
      Uint8List? b;
      try {
        b = await f(widget.item.file.path, times[i]);
      } catch (_) {}
      if (_disposed || times != _times) return;
      setState(() => _thumbs[i] = b);
    }
  }

  static Future<Uint8List?> _frame(String path, int ms) =>
      VideoFrames.bytes(path, ms, maxHeight: 260, quality: 70);

  void _pick(int i) {
    setState(() {
      _selected = i;
      _coverMs = _times[i];
    });
    _seek();
  }

  @override
  void dispose() {
    _disposed = true;
    _strip.dispose();
    _c?.dispose();
    super.dispose();
  }

  Widget _bigPreview() {
    final c = _c;
    final e = widget.item.edits;
    if (c != null && _videoReady) {
      // v0.0.2: texts / stickers of this moment too
      return AspectRatio(
        aspectRatio: safeAspect(widget.item.aspectRatio),
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // same as the editor: the video fills its own shape
              applyMatrix(e.filter, VideoPlayer(c)),
              if (e.face case final fx?) FaceFxLayer(fx: fx, controller: c),
              StillOverlays(
                key: const ValueKey('cover-overlays'),
                overlays: e.overlays,
                ms: _ms,
              ),
            ],
          ),
        ),
      );
    }
    final b = _thumbs[_selected];
    if (b != null) {
      return EditedFrame(
        key: const ValueKey('cover-edited-frame'),
        frame: MemoryImage(b),
        edits: e,
        aspect: widget.item.aspectRatio,
        ms: _ms,
      );
    }
    return AspectRatio(
      aspectRatio: safeAspect(widget.item.aspectRatio),
      child: const ShimmerFill(radius: 16),
    );
  }

  Widget _frameTile(int i) {
    final b = _thumbs[i];
    final on = i == _selected;
    final ar = widget.item.aspectRatio.clamp(0.5, 1.2).toDouble();
    return GestureDetector(
      key: ValueKey('cover-frame-$i'),
      onTap: () => _pick(i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: on ? AppColors.lime : Colors.transparent,
            width: 2.5,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: AspectRatio(
            aspectRatio: ar,
            child: b == null
                ? Container(
                    color: AppColors.surfaceHigh,
                    alignment: Alignment.center,
                    child: _thumbs.containsKey(i)
                        ? const Icon(
                            Icons.broken_image_outlined,
                            size: 18,
                            color: AppColors.textHint,
                          )
                        : const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                  )
                : Opacity(
                    opacity: on ? 1 : 0.75,
                    // v0.0.2: filter + texts / stickers of that moment
                    child: FittedBox(
                      fit: BoxFit.cover,
                      clipBehavior: Clip.hardEdge,
                      child: SizedBox(
                        width: 100 * safeAspect(widget.item.aspectRatio),
                        height: 100,
                        child: EditedFrame(
                          frame: MemoryImage(b),
                          edits: widget.item.edits,
                          aspect: widget.item.aspectRatio,
                          ms: _times[i],
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canDone = _times.isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Choose cover'),
        actions: [
          TextButton(
            key: const ValueKey('cover-done'),
            onPressed: canDone ? () => Navigator.pop(context, _ms) : null,
            child: const Text(
              'Done',
              style: TextStyle(
                color: AppColors.lime,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: Center(child: _bigPreview())),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 16),
              child: Column(
                children: [
                  SizedBox(
                    height: 104,
                    child: ListView.builder(
                      key: const ValueKey('cover-frames'),
                      controller: _strip,
                      scrollDirection: Axis.horizontal,
                      itemExtent: _tileW,
                      itemCount: _times.length,
                      itemBuilder: (_, i) => _frameTile(i),
                    ),
                  ),
                  // v0.19: slide to any moment
                  if (_times.length > 1)
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: AppColors.lime,
                        inactiveTrackColor: AppColors.surfaceHigh,
                        thumbColor: AppColors.lime,
                        overlayColor: AppColors.lime.withValues(alpha: 0.15),
                        trackHeight: 3,
                      ),
                      child: Slider(
                        key: const ValueKey('cover-slider'),
                        min: _times.first.toDouble(),
                        max: _times.last.toDouble(),
                        value: _ms.clamp(_times.first, _times.last).toDouble(),
                        onChanged: _slide,
                        onChangeEnd: (_) => _seek(),
                      ),
                    )
                  else
                    const SizedBox(height: 10),
                  Text(
                    _times.isEmpty
                        ? 'Loading frames…'
                        : 'Slide or tap a frame · '
                              '${durationLabel(_ms - _times.first)}',
                    key: const ValueKey('cover-time'),
                    style: const TextStyle(color: AppColors.textSecondary),
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

/// v0.16: choose one of your highlights, or make a new one.
/// Pops (id, title).
class _HighlightChooser extends StatefulWidget {
  const _HighlightChooser({required this.stream});

  final Stream<List<Highlight>> stream;

  @override
  State<_HighlightChooser> createState() => _HighlightChooserState();
}

class _HighlightChooserState extends State<_HighlightChooser> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _createNew() async {
    // v0.19 Hyper Intelligence: no strong abuse in the name
    if (!await hiTextOk(context, [_name.text]) || !mounted) return;
    final title = Highlight.cleanTitle(_name.text);
    Navigator.pop(context, (HighlightRepository.instance.newIdSafe(), title));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Add to highlight',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('hl-new-name'),
                        controller: _name,
                        maxLength: Highlight.maxTitle,
                        decoration: const InputDecoration(
                          counterText: '',
                          hintText: 'New highlight name',
                          isDense: true,
                        ),
                        onSubmitted: (_) => _createNew(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const ValueKey('hl-new-create'),
                      onPressed: _createNew,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.lime,
                        foregroundColor: Colors.black,
                        textStyle: const TextStyle(
                          fontFamily: AppTheme.fontFamily,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      child: const Text('Create'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: StreamBuilder<List<Highlight>>(
                  stream: widget.stream,
                  builder: (context, snap) {
                    final list = snap.data ?? const <Highlight>[];
                    if (!snap.hasData && !snap.hasError) {
                      return const Padding(
                        padding: EdgeInsets.all(20),
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                      );
                    }
                    if (list.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.fromLTRB(20, 8, 20, 16),
                        child: Text(
                          'No highlights yet. Type a name and tap Create.',
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      );
                    }
                    return ListView(
                      shrinkWrap: true,
                      children: [
                        for (final h in list)
                          ListTile(
                            key: ValueKey('hl-choose-${h.id}'),
                            leading: CircleAvatar(
                              backgroundColor: AppColors.surfaceHigh,
                              backgroundImage: h.coverUrl.isEmpty
                                  ? null
                                  : NetworkImage(h.coverUrl),
                              child: h.coverUrl.isEmpty
                                  ? const Icon(Icons.bookmark, size: 18)
                                  : null,
                            ),
                            title: Text(
                              h.title,
                              style: const TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              h.items.length >= Highlight.maxItems
                                  ? 'Full (${Highlight.maxItems})'
                                  : '${h.items.length} '
                                        '${h.items.length == 1 ? 'item' : 'items'}',
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                              ),
                            ),
                            enabled: h.items.length < Highlight.maxItems,
                            onTap: () =>
                                Navigator.pop(context, (h.id, h.title)),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// v0.20: why you can't share right now (null = you can).
Future<String?> postingStopReason({required bool isStory}) async {
  final until = await PostRepository.instance.postingBlockedUntil();
  if (until != null) {
    return 'You broke the community rules 2 times. '
        'You can post again on ${fullDate(until)}.';
  }
  return isStory ? null : SpamGuard.instance.checkPost();
}
