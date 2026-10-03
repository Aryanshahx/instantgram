import 'dart:io';

import 'package:image_picker/image_picker.dart';

/// Client-side compression happens here: images are resized + re-encoded as
/// JPEG by the picker BEFORE they are uploaded, so the media server only stores small files.
class MediaService {
  static final ImagePicker _picker = ImagePicker();

  /// Feed photos: max 1080 x 1350, JPEG quality 70  (~150-300 KB each).
  static Future<File?> pickPostImage(ImageSource source) =>
      _pick(source, maxWidth: 1080, maxHeight: 1350, quality: 70);

  /// Profile pictures: max 512 x 512, JPEG quality 75  (~30-60 KB).
  static Future<File?> pickAvatar(ImageSource source) =>
      _pick(source, maxWidth: 512, maxHeight: 512, quality: 75);

  /// Stories: max 1080 x 1920, JPEG quality 70.
  static Future<File?> pickStoryImage(ImageSource source) =>
      _pick(source, maxWidth: 1080, maxHeight: 1920, quality: 70);

  static Future<File?> _pick(
    ImageSource source, {
    required double maxWidth,
    required double maxHeight,
    required int quality,
  }) async {
    final x = await _picker.pickImage(
      source: source,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      imageQuality: quality,
    );
    return x == null ? null : File(x.path);
  }
}
