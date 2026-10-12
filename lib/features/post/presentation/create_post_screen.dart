import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/services/media_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/post.dart';
import '../../../shared/widgets/ig_buttons.dart';
import '../../editor/bake_filter.dart';
import '../../editor/edit_models.dart';
import '../../editor/filters.dart';
import '../../editor/video_frames.dart';
import '../../stories/data/story_repository.dart';
import '../data/post_repository.dart';

export '../../editor/edit_models.dart' show ComposeMode, EditedMedia;

/// Share screen (after the editor): big preview, caption, cover,
/// audience, "also share to moment" and hidden counts.
class CreatePostScreen extends StatefulWidget {
  const CreatePostScreen({super.key, required this.items, required this.mode});

  final List<EditedMedia> items;
  final ComposeMode mode;

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

  /// Clip cover chosen by the user (already filtered if from the video).
  File? _cover;
  bool _coverFromGallery = false;
  bool _makingCover = false;

  double? _progress; // null = not uploading
  String? _error;

  bool get _isClip => widget.mode == ComposeMode.clip;
  bool get _isStory => widget.mode == ComposeMode.story;

  @override
  void dispose() {
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
    final baked = f == null ? null : await bakeFilter(f, item.edits.filter);
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
  );

  Future<void> _share() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _progress = 0;
      _error = null;
    });
    void onProgress(double v) {
      if (mounted) setState(() => _progress = v.clamp(0, 1));
    }

    try {
      final items = widget.items;
      switch (widget.mode) {
        case ComposeMode.photo:
          await PostRepository.instance.createPhotos(
            photos: [for (final m in items) PhotoUpload(m.file, m.aspectRatio)],
            caption: _caption.text,
            options: _options,
            onProgress: onProgress,
          );
        case ComposeMode.clip:
          final v = items.first;
          var thumb = _cover;
          if (thumb == null && v.preview != null) {
            thumb = await bakeFilter(v.preview!, v.edits.filter);
          }
          await PostRepository.instance.createClip(
            video: v.file,
            aspectRatio: v.aspectRatio,
            caption: _caption.text,
            thumb: thumb,
            edits: v.edits,
            durationMs: v.durationMs,
            options: _options,
            onProgress: onProgress,
          );
        case ComposeMode.story:
          final n = items.length;
          for (var i = 0; i < n; i++) {
            final m = items[i];
            await StoryRepository.instance.create(
              m.file,
              isVideo: m.isVideo,
              edits: m.edits,
              durationMs: m.durationMs,
              audience: _audience,
              onProgress: (v) => onProgress((i + v) / n),
            );
          }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isStory
                ? (widget.items.length > 1
                      ? '${widget.items.length} moments shared ✨'
                      : 'Moment shared ✨')
                : _isClip
                ? 'Clip shared 🎬'
                : 'Post shared 🎉',
          ),
        ),
      );
      Navigator.of(context).popUntil((r) => r.isFirst);
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
    if (!m.isVideo) return Image.file(m.file, fit: fit, gaplessPlayback: true);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (m.preview != null)
          applyMatrix(m.edits.filter, Image.file(m.preview!, fit: fit))
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
          child: _Pill(
            icon: m.edits.muted ? Icons.volume_off : Icons.videocam,
            text: durationLabel(m.durationMs),
          ),
        ),
      ],
    );
  }

  Widget _preview(double height) {
    final items = widget.items;
    if (_isClip) {
      final v = items.first;
      final Widget img;
      if (_cover != null) {
        img = Image.file(_cover!, fit: BoxFit.cover, gaplessPlayback: true);
      } else if (v.preview != null) {
        img = applyMatrix(
          v.edits.filter,
          Image.file(v.preview!, fit: BoxFit.cover, gaplessPlayback: true),
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
                    child: _Pill(
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
                    child: _Pill(
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
              child: _Pill(text: '${_page + 1}/${items.length}'),
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

  Widget _card(List<Widget> children) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: AppColors.border),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(children: children),
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
                  if (_isClip) ...[
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
class CoverPickerScreen extends StatefulWidget {
  const CoverPickerScreen({super.key, required this.item});
  final EditedMedia item;

  @override
  State<CoverPickerScreen> createState() => _CoverPickerScreenState();
}

class _CoverPickerScreenState extends State<CoverPickerScreen> {
  VideoPlayerController? _c;
  bool _ready = false;
  int _start = 0;
  int _end = 1;
  int _ms = 0;

  @override
  void initState() {
    super.initState();
    final c = VideoPlayerController.file(widget.item.file);
    _c = c;
    c
        .initialize()
        .then((_) async {
          if (!mounted) return;
          final total = c.value.duration.inMilliseconds;
          final e = widget.item.edits;
          _start = e.trimStartMs.clamp(0, total);
          _end = (e.trimEndMs > 0 ? e.trimEndMs : total).clamp(
            _start + 1,
            total,
          );
          _ms = _start;
          await c.setVolume(0);
          await c.seekTo(Duration(milliseconds: _ms));
          setState(() => _ready = true);
        })
        .catchError((Object _) {
          if (mounted) setState(() => _ready = false);
        });
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Choose cover'),
        actions: [
          TextButton(
            onPressed: _ready ? () => Navigator.pop(context, _ms) : null,
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
          Expanded(
            child: Center(
              child: c == null || !_ready
                  ? const CircularProgressIndicator()
                  : AspectRatio(
                      aspectRatio: c.value.aspectRatio,
                      child: applyMatrix(
                        widget.item.edits.filter,
                        VideoPlayer(c),
                      ),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              children: [
                Slider(
                  value: _ms.toDouble().clamp(
                    _start.toDouble(),
                    _end.toDouble(),
                  ),
                  min: _start.toDouble(),
                  max: _end.toDouble(),
                  activeColor: AppColors.lime,
                  onChanged: !_ready
                      ? null
                      : (v) {
                          setState(() => _ms = v.round());
                          c?.seekTo(Duration(milliseconds: _ms));
                        },
                ),
                Text(
                  'Slide to pick a frame · ${durationLabel(_ms - _start)}',
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small dark pill label.
class _Pill extends StatelessWidget {
  const _Pill({required this.text, this.icon});
  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// Carousel dots.
class PageDots extends StatelessWidget {
  const PageDots({super.key, required this.count, required this.index});
  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 2.5),
            width: i == index ? 16 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == index ? AppColors.lime : Colors.white54,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}
