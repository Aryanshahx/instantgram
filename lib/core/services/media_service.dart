import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../theme/app_colors.dart';
import 'api_client.dart';

/// What the file is used for (decides the folder in Tigris + size limits).
enum MediaKind { post, clip, story, avatar, cover }

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
              leading: const Icon(Icons.photo_library_outlined,
                  color: AppColors.lime),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open picker: $e')),
        );
      }
      return null;
    }
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

    final response =
        await responseFuture.timeout(const Duration(minutes: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw ApiException(
        'Upload failed (${response.statusCode}). ${body.length > 200 ? body.substring(0, 200) : body}',
      );
    }
    return UploadedMedia(
      url: sign['publicUrl'] as String,
      key: sign['key'] as String,
    );
  }

  /// Delete a file from Tigris (ignored if it fails).
  Future<void> delete(String key) async {
    if (key.isEmpty) return;
    try {
      await ApiClient.instance.post('/api/delete-media', {'key': key});
    } catch (_) {}
  }
}
