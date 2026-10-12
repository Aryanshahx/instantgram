import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/errors.dart';
import '../../../shared/widgets/ig_buttons.dart';
import '../../stories/data/story_repository.dart';
import '../data/post_repository.dart';

enum ComposeMode { photo, clip, story }

class CreatePostScreen extends StatefulWidget {
  const CreatePostScreen({super.key, required this.file, required this.mode});

  final File file;
  final ComposeMode mode;

  @override
  State<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends State<CreatePostScreen> {
  final _caption = TextEditingController();
  VideoPlayerController? _video;
  double _aspect = 1;
  double? _progress; // null = not uploading
  String? _error;

  bool get _isClip => widget.mode == ComposeMode.clip;
  bool get _isStory => widget.mode == ComposeMode.story;

  @override
  void initState() {
    super.initState();
    if (_isClip) {
      _video = VideoPlayerController.file(widget.file)
        ..setLooping(true)
        ..initialize().then((_) {
          if (!mounted) return;
          setState(() => _aspect = _video!.value.aspectRatio);
          _video!.play();
        });
    } else {
      _readImageSize();
    }
  }

  Future<void> _readImageSize() async {
    try {
      final bytes = await widget.file.readAsBytes();
      final img = await decodeImageFromList(bytes);
      if (mounted && img.height > 0) {
        setState(() => _aspect = img.width / img.height);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _caption.dispose();
    _video?.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    FocusScope.of(context).unfocus();
    _video?.pause();
    setState(() {
      _progress = 0;
      _error = null;
    });
    void onProgress(double v) {
      if (mounted) setState(() => _progress = v);
    }

    try {
      if (_isStory) {
        await StoryRepository.instance.create(widget.file, onProgress: onProgress);
      } else {
        await PostRepository.instance.create(
          file: widget.file,
          isClip: _isClip,
          caption: _caption.text,
          aspectRatio: _aspect,
          onProgress: onProgress,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_isStory
              ? 'Story shared ✨'
              : _isClip
                  ? 'Clip shared 🎬'
                  : 'Post shared 🎉'),
        ),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final uploading = _progress != null;
    final title = _isStory
        ? 'New story'
        : _isClip
            ? 'New clip'
            : 'New post';

    return PopScope(
      canPop: !uploading,
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.55,
                ),
                child: AspectRatio(
                  aspectRatio: _aspect.clamp(0.5, 2.0),
                  child: _isClip
                      ? (_video != null && _video!.value.isInitialized
                          ? GestureDetector(
                              onTap: () => setState(() => _video!.value.isPlaying
                                  ? _video!.pause()
                                  : _video!.play()),
                              child: VideoPlayer(_video!),
                            )
                          : const ColoredBox(
                              color: AppColors.surface,
                              child: Center(child: CircularProgressIndicator()),
                            ))
                      : Image.file(widget.file, fit: BoxFit.cover),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (!_isStory)
              TextField(
                controller: _caption,
                enabled: !uploading,
                maxLines: 4,
                minLines: 2,
                maxLength: 2200,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Write a caption…',
                  hintStyle: const TextStyle(color: AppColors.textHint),
                  filled: true,
                  fillColor: AppColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: const BorderSide(color: AppColors.lime),
                  ),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: AppColors.like)),
            ],
            const SizedBox(height: 12),
            if (uploading) ...[
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
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ] else
              IgPrimaryButton(
                label: _isStory ? 'Share to story' : 'Share',
                onPressed: _share,
              ),
          ],
        ),
      ),
    );
  }
}

