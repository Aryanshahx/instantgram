import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/video_link.dart';
import '../../services/post_service.dart';
import '../../services/storage_service.dart';
import '../../widgets/pill_tabs.dart';
import '../../widgets/video_embed.dart';

class CreatePostScreen extends StatefulWidget {
  const CreatePostScreen({super.key});

  @override
  State<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends State<CreatePostScreen> {
  int _mode = 0; // 0 = photo, 1 = video link
  File? _image;
  int? _imageKb;
  final _caption = TextEditingController();
  final _link = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _caption.dispose();
    _link.dispose();
    super.dispose();
  }

  VideoLink? get _parsed => VideoLink.parse(_link.text);

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
                title: const Text('Choose from gallery',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                onTap: () => Navigator.pop(ctx, ImageSource.gallery),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_rounded),
                title: const Text('Take a photo',
                    style: TextStyle(fontWeight: FontWeight.w700)),
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

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      setState(() => _link.text = data!.text!.trim());
    }
  }

  bool get _canShare {
    if (_busy) return false;
    return _mode == 0 ? _image != null : _parsed != null;
  }

  Future<void> _share() async {
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      if (_mode == 0) {
        await PostService.instance
            .createImagePost(image: _image!, caption: _caption.text);
      } else {
        final video = await VideoLinkResolver.resolve(_link.text);
        await PostService.instance
            .createVideoPost(video: video, caption: _caption.text);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        ),
        title: const Text('Create'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              children: [
                PillTabs(
                  labels: const ['Photo', 'Video link'],
                  icons: const [Icons.image_rounded, Icons.smart_display_rounded],
                  index: _mode,
                  onChanged: (i) {
                    if (!_busy) setState(() => _mode = i);
                  },
                ),
                const SizedBox(height: 18),
                if (_mode == 0) _photoPicker(context) else _videoLink(context),
                const SizedBox(height: 16),
                TextField(
                  controller: _caption,
                  enabled: !_busy,
                  maxLines: 4,
                  minLines: 3,
                  maxLength: 500,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                      hintText: 'Say something about it...'),
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
                            strokeWidth: 2.5, color: AppTheme.ink),
                      )
                    : const Icon(Icons.bolt_rounded),
                label: Text(_busy
                    ? (_mode == 0 ? 'Uploading...' : 'Checking link...')
                    : 'Publish'),
              ),
            ),
          ),
        ],
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
                  child: const Icon(Icons.add_photo_alternate_rounded,
                      size: 38, color: AppTheme.ink),
                ),
                const SizedBox(height: 16),
                const Text('Pick a photo',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text('Shrunk on your phone first to save space',
                    style: TextStyle(color: context.muted)),
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
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.compress_rounded,
                        size: 16, color: AppTheme.volt),
                    const SizedBox(width: 6),
                    Text('${_imageKb ?? 0} KB after compression',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5)),
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
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: AppTheme.volt,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Text('Change',
                      style: TextStyle(
                          color: AppTheme.ink, fontWeight: FontWeight.w800)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _videoLink(BuildContext context) {
    final parsed = _parsed;
    final hasText = _link.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _link,
          enabled: !_busy,
          keyboardType: TextInputType.url,
          autocorrect: false,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Paste a YouTube Short, TikTok or Reel link',
            prefixIcon: const Icon(Icons.link_rounded),
            suffixIcon: IconButton(
              tooltip: 'Paste',
              icon: const Icon(Icons.content_paste_rounded),
              onPressed: _paste,
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (parsed != null)
          _LinkPreview(link: parsed)
        else if (hasText)
          Row(
            children: [
              const Icon(Icons.error_outline_rounded,
                  size: 18, color: AppTheme.coral),
              const SizedBox(width: 6),
              Text('That link is not supported yet.',
                  style: TextStyle(color: context.muted)),
            ],
          )
        else
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: context.card,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: context.hairline.withValues(alpha: 0.7)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, color: context.accentInk),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Nothing is uploaded. We only save the link, and the video '
                    'plays straight from YouTube, TikTok or Instagram.',
                    style: TextStyle(color: context.muted, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _LinkPreview extends StatelessWidget {
  const _LinkPreview({required this.link});
  final VideoLink link;

  @override
  Widget build(BuildContext context) {
    final thumb = link.platform == VideoPlatform.youtube && link.id != null
        ? VideoLinkResolver.youtubeThumbnail(link.id!)
        : null;
    return Container(
      decoration: BoxDecoration(
        color: context.card,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: context.hairline.withValues(alpha: 0.7)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          SizedBox(
            width: 116,
            height: 92,
            child: thumb == null
                ? ColoredBox(
                    color: context.cardHigh,
                    child: Icon(Icons.smart_display_rounded,
                        color: context.muted, size: 38),
                  )
                : Image.network(thumb,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => ColoredBox(color: context.cardHigh)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.check_circle_rounded,
                        color: Colors.green, size: 18),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text('${link.platform.label} link ready',
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                TextButton(
                  style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 30),
                      alignment: Alignment.centerLeft),
                  onPressed: () => openExternally(link.url),
                  child: const Text('Test link'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
