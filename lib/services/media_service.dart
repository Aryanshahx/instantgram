import 'dart:io';

import 'package:image_picker/image_picker.dart';

import '../core/config.dart';
import '../core/errors.dart';

/// Photo pickers.
///
/// Post photos and moments are uploaded exactly as taken (original quality, nothing is
/// recompressed on the phone). The bucket stores and serves that exact file.
/// Profile pictures are still resized, because they appear as tiny circles all over the app.
class MediaService {
  static final ImagePicker _picker = ImagePicker();

  static Future<File?> pickPostImage(ImageSource source) =>
      _pickOriginal(source);

  /// Photos and videos from the gallery, exactly as they are (no resizing). With [limit] 1 the
  /// phone's single picker is used.
  static Future<List<XFile>> pickGalleryMedia({int limit = 10}) async {
    if (limit <= 1) {
      final x = await _picker.pickMedia();
      return x == null ? const [] : [x];
    }
    return _picker.pickMultipleMedia(limit: limit);
  }

  /// Moments last 24 hours and are only ever shown full screen on a phone, so they are
  /// saved at up to 1440 x 2560 (JPEG quality 88, usually a few hundred KB). That is why they
  /// open instantly for everyone instead of downloading a multi-megabyte original.
  static Future<File?> pickStoryImage(ImageSource source) async {
    final x = await _picker.pickImage(
      source: source,
      maxWidth: 1440,
      maxHeight: 2560,
      imageQuality: 88,
    );
    if (x == null) return null;
    final file = File(x.path);
    if (!await isSupportedImage(file)) {
      throw const MediaException(
        'This photo format is not supported. Use a JPEG, PNG or WebP photo.',
      );
    }
    return file;
  }

  /// Photo for a photo clip: up to 1600 px, JPEG quality 90 (loads fast in Clips).
  static Future<File?> pickClipImage(ImageSource source) async {
    final x = await _picker.pickImage(
      source: source,
      maxWidth: 1600,
      maxHeight: 2400,
      imageQuality: 90,
    );
    if (x == null) return null;
    final file = File(x.path);
    if (!await isSupportedImage(file)) {
      throw const MediaException(
        'This photo format is not supported. Use a JPEG, PNG or WebP photo.',
      );
    }
    return file;
  }

  /// Photo sent in a chat: up to 1920 px, JPEG quality 88 (sends fast).
  static Future<File?> pickChatImage(ImageSource source) async {
    final x = await _picker.pickImage(
      source: source,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 88,
    );
    if (x == null) return null;
    final file = File(x.path);
    if (!await isSupportedImage(file)) {
      throw const MediaException(
        'This photo format is not supported. Use a JPEG, PNG or WebP photo.',
      );
    }
    return file;
  }

  /// Profile pictures: max 512 x 512, JPEG quality 75 (about 30-60 KB).
  static Future<File?> pickAvatar(ImageSource source) async {
    final x = await _picker.pickImage(
      source: source,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 75,
    );
    return x == null ? null : File(x.path);
  }

  /// Profile cover: max 1600 px wide, JPEG quality 85.
  static Future<File?> pickBanner(ImageSource source) async {
    final x = await _picker.pickImage(
      source: source,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 85,
    );
    return x == null ? null : File(x.path);
  }

  static Future<File?> _pickOriginal(ImageSource source) async {
    final x = await _picker.pickImage(source: source);
    if (x == null) return null;
    final file = File(x.path);
    if (await file.length() > kMaxImageMb * 1024 * 1024) {
      throw const MediaException(
        'This photo is larger than $kMaxImageMb MB. Pick a smaller one.',
      );
    }
    if (!await isSupportedImage(file)) {
      throw const MediaException(
        'This photo format is not supported. Use a JPEG, PNG or WebP photo '
        '(in the camera settings choose the most compatible format).',
      );
    }
    return file;
  }

  /// True for JPEG, PNG, GIF and WebP (what the media service accepts).
  static Future<bool> isSupportedImage(File file) async {
    final head = <int>[];
    await for (final part in file.openRead(0, 12)) {
      head.addAll(part);
    }
    bool starts(List<int> sig) =>
        head.length >= sig.length &&
        List.generate(sig.length, (i) => head[i] == sig[i]).every((e) => e);
    final jpeg = starts([0xFF, 0xD8, 0xFF]);
    final png = starts([0x89, 0x50, 0x4E, 0x47]);
    final gif = starts([0x47, 0x49, 0x46, 0x38]);
    final webp =
        starts([0x52, 0x49, 0x46, 0x46]) &&
        head.length >= 12 &&
        head[8] == 0x57 &&
        head[9] == 0x45 &&
        head[10] == 0x42 &&
        head[11] == 0x50;
    return jpeg || png || gif || webp;
  }
}
