import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../theme/app_colors.dart';
import 'api_client.dart';

/// What the file is used for (decides the folder in Tigris + size limits).
enum MediaKind { post, clip, story, avatar, cover, thumb, audio }

/// What the create flow may pick.
enum PickKind {
  /// Posts and clips: any number of photos and videos.
  mixed,

  /// Moments: photos and/or videos (videos up to 60 s).
  moment,
}

/// A music file picked from the phone.
class PickedAudio {
  const PickedAudio(this.file, this.name);
  final File file;

  /// File name without the extension (shown to people).
  final String name;
}

/// Music file types we accept.
const Set<String> kAudioExtensions = {'mp3', 'm4a', 'aac', 'wav', 'ogg'};

/// Max music file size (same limit as the server).
const int kMaxAudioBytes = 20 * 1024 * 1024;

/// A picked file from the gallery or camera.
class PickedMedia {
  const PickedMedia(this.file, {required this.isVideo});
  final File file;
  final bool isVideo;
}

bool isVideoPath(String path) {
  final ext = path.split('.').last.toLowerCase();
  return const {'mp4', 'mov', 'webm', '3gp', 'mkv', 'm4v', 'avi'}.contains(ext);
}

class UploadedMedia {
  const UploadedMedia({required this.url, required this.key});
  final String url;
  final String key;
}

class MediaService {
  MediaService._();
  static final MediaService instance = MediaService._();

  final ImagePicker _picker = ImagePicker();

  static const Map<String, String> _types = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
    'heic': 'image/heic',
    'gif': 'image/gif',
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
    'webm': 'video/webm',
    '3gp': 'video/3gpp',
    'mkv': 'video/x-matroska',
    'm4v': 'video/mp4',
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'wav': 'audio/wav',
    'ogg': 'audio/ogg',
  };

  String contentTypeFor(String path) {
    final ext = path.split('.').last.toLowerCase();
    return _types[ext] ?? 'application/octet-stream';
  }

  /// Ask "Gallery or Camera?" then pick a photo or video.
  Future<File?> pick(
    BuildContext context, {
    bool video = false,
    double maxWidth = 1440,
  }) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.photo_library_outlined,
                color: AppColors.lime,
              ),
              title: Text(video ? 'Choose video' : 'Choose from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: Icon(
                video ? Icons.videocam_outlined : Icons.photo_camera_outlined,
                color: AppColors.lime,
              ),
              title: Text(video ? 'Record video' : 'Take photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null) return null;

    try {
      final XFile? x = video
          ? await _picker.pickVideo(
              source: source,
              maxDuration: const Duration(seconds: 90),
            )
          : await _picker.pickImage(
              source: source,
              maxWidth: maxWidth,
              imageQuality: 85,
            );
      return x == null ? null : File(x.path);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not open picker: $e')));
      }
      return null;
    }
  }

  /// Create flow picker: Gallery (any number) or Camera.
  Future<List<PickedMedia>> pickForCreate(
    BuildContext context,
    PickKind kind,
  ) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('pick-gallery'),
              leading: const Icon(
                Icons.photo_library_outlined,
                color: AppColors.lime,
              ),
              title: const Text('Choose photos or videos'),
              subtitle: const Text('Pick as many as you like'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(
                Icons.photo_camera_outlined,
                color: AppColors.lime,
              ),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(ctx, 'photo'),
            ),
            ListTile(
              leading: const Icon(
                Icons.videocam_outlined,
                color: AppColors.lime,
              ),
              title: const Text('Record video'),
              onTap: () => Navigator.pop(ctx, 'video'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null) return const [];

    try {
      switch (choice) {
        case 'photo':
          final x = await _picker.pickImage(
            source: ImageSource.camera,
            maxWidth: 2048,
            imageQuality: 92,
          );
          return x == null
              ? const []
              : [PickedMedia(File(x.path), isVideo: false)];
        case 'video':
          final x = await _picker.pickVideo(
            source: ImageSource.camera,
            maxDuration: Duration(seconds: kind == PickKind.moment ? 60 : 90),
          );
          return x == null
              ? const []
              : [PickedMedia(File(x.path), isVideo: true)];
      }
      // gallery: photos and videos together, no limit
      final xs = await _picker.pickMultipleMedia(
        maxWidth: 2048,
        imageQuality: 92,
      );
      return xs
          .map((x) => PickedMedia(File(x.path), isVideo: isVideoPath(x.path)))
          .toList();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not open picker: $e')));
      }
      return const [];
    }
  }

  /// Music from phone storage (mp3, m4a, aac, wav, ogg). Null = cancelled.
  /// Throws a [StateError] with a friendly message when the file is not ok.
  Future<PickedAudio?> pickAudio() async {
    final f = await FilePicker.pickFile(type: FileType.audio);
    if (f == null) return null;
    final name = f.name;
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    if (!kAudioExtensions.contains(ext)) {
      throw StateError('Please pick an MP3, M4A, AAC, WAV or OGG file');
    }
    File file;
    final path = f.path;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      file = File(path);
    } else {
      // content:// file -> copy it to a temp file
      final bytes = await f.readAsBytes();
      final dir = await Directory.systemTemp.createTemp('ig_audio');
      file = File(
        '${dir.path}/music_${DateTime.now().millisecondsSinceEpoch}.$ext',
      );
      await file.writeAsBytes(bytes, flush: true);
    }
    if (await file.length() > kMaxAudioBytes) {
      throw StateError('Music file is too big (max 20 MB)');
    }
    return PickedAudio(file, audioTitle(name));
  }

  /// One photo from the gallery (used for clip covers).
  Future<File?> pickGalleryImage({double maxWidth = 1440}) async {
    final x = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: maxWidth,
      imageQuality: 88,
    );
    return x == null ? null : File(x.path);
  }

  /// 1) ask the backend for a presigned URL  2) PUT the file to Tigris.
  Future<UploadedMedia> upload(
    File file, {
    required MediaKind kind,
    ValueChanged<double>? onProgress,
  }) async {
    final contentType = contentTypeFor(file.path);
    final size = await file.length();

    final sign = await ApiClient.instance.post('/api/upload-url', {
      'kind': kind.name,
      'contentType': contentType,
      'size': size,
    });

    final uploadUrl = sign['uploadUrl'] as String;
    final headers = Map<String, String>.from(
      (sign['headers'] as Map?) ?? {'Content-Type': contentType},
    );

    final request = http.StreamedRequest('PUT', Uri.parse(uploadUrl))
      ..headers.addAll(headers)
      ..contentLength = size;

    final responseFuture = request.send();
    var sent = 0;
    onProgress?.call(0);
    await for (final chunk in file.openRead()) {
      request.sink.add(chunk);
      sent += chunk.length;
      onProgress?.call(size == 0 ? 1 : sent / size);
    }
    await request.sink.close();

    final response = await responseFuture.timeout(const Duration(minutes: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw ApiException(_storageError(response.statusCode, body));
    }
    return UploadedMedia(
      url: sign['publicUrl'] as String,
      key: sign['key'] as String,
    );
  }

  /// Turns a Tigris XML error into a short, readable message.
  static String _storageError(int status, String body) {
    final code =
        RegExp(r'<Code>([^<]+)</Code>').firstMatch(body)?.group(1) ?? '';
    switch (code) {
      case 'NoSuchBucket':
        return 'Upload failed: storage bucket not found. '
            'Check TIGRIS_BUCKET on Vercel.';
      case 'InvalidAccessKeyId':
      case 'SignatureDoesNotMatch':
        return 'Upload failed: storage keys are wrong. '
            'Check TIGRIS_ACCESS_KEY_ID / TIGRIS_SECRET_ACCESS_KEY on Vercel.';
      case 'AccessDenied':
        return 'Upload failed: access denied by storage. '
            'Check the Tigris access key permissions.';
      case 'RequestTimeTooSkewed':
        return 'Upload failed: your phone clock is wrong. Fix date & time.';
      case 'EntityTooLarge':
        return 'Upload failed: file is too big.';
      default:
        return 'Upload failed ($status${code.isEmpty ? '' : ' $code'}). Try again.';
    }
  }

  /// Delete a file from Tigris (ignored if it fails).
  Future<void> delete(String key) async {
    if (key.isEmpty) return;
    try {
      await ApiClient.instance.post('/api/delete-media', {'key': key});
    } catch (_) {}
  }
}

/// "My Song (Remix).mp3" -> "My Song (Remix)"
String audioTitle(String fileName) {
  final slash = fileName.lastIndexOf('/');
  var n = slash < 0 ? fileName : fileName.substring(slash + 1);
  final dot = n.lastIndexOf('.');
  if (dot > 0) n = n.substring(0, dot);
  n = n.replaceAll('_', ' ').trim();
  if (n.isEmpty) return 'Music';
  return n.length > 60 ? '${n.substring(0, 60)}…' : n;
}
