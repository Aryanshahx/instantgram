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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
          ],
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
          icon: const Icon(Icons.close),
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        ),
        title: const Text('New post',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          TextButton(
            onPressed: _canShare ? _share : null,
            child: _busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Share',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                  value: 0,
                  icon: Icon(Icons.photo_outlined),
                  label: Text('Photo')),
              ButtonSegment(
                  value: 1,
                  icon: Icon(Icons.smart_display_outlined),
                  label: Text('Video link')),
            ],
            selected: {_mode},
            onSelectionChanged:
                _busy ? null : (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(height: 16),
          if (_mode == 0) _photoPicker(context) else _videoLink(context),
          const SizedBox(height: 16),
          TextField(
            controller: _caption,
            enabled: !_busy,
            maxLines: 4,
            minLines: 2,
            maxLength: 500,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Write a caption...'),
          ),
          if (_busy)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _mode == 0 ? 'Uploading photo...' : 'Checking link...',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.muted),
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
          aspectRatio: 4 / 5,
          child: Container(
            decoration: BoxDecoration(
              color: context.softFill,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.hairline),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add_photo_alternate_outlined,
                    size: 56, color: context.muted),
                const SizedBox(height: 8),
                Text('Tap to choose a photo',
                    style: TextStyle(color: context.muted)),
              ],
            ),
          ),
        ),
      );
    }
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: 4 / 5,
            child: Image.file(_image!, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Compressed to ${_imageKb ?? 0} KB',
                style: TextStyle(color: context.muted, fontSize: 12)),
            TextButton.icon(
              onPressed: _busy ? null : _pickImage,
              icon: const Icon(Icons.swap_horiz),
              label: const Text('Change'),
            ),
          ],
        ),
      ],
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
            prefixIcon: const Icon(Icons.link),
            suffixIcon: IconButton(
              tooltip: 'Paste',
              icon: const Icon(Icons.content_paste),
              onPressed: _paste,
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (parsed != null)
          _LinkPreview(link: parsed)
        else if (hasText)
          Text('Not a supported link yet.',
              style: TextStyle(color: Colors.red.shade400))
        else
          Text(
            'Videos are not uploaded. Only the link is saved, and the video '
            'plays from YouTube, TikTok or Instagram.',
            style: TextStyle(color: context.muted),
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
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          SizedBox(
            width: 110,
            height: 80,
            child: thumb == null
                ? ColoredBox(
                    color: context.softFill,
                    child: Icon(Icons.smart_display, color: context.muted, size: 36),
                  )
                : Image.network(thumb, fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => ColoredBox(color: context.softFill)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green, size: 18),
                    const SizedBox(width: 6),
                    Text('${link.platform.label} link detected',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 4),
                TextButton(
                  style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 28),
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
