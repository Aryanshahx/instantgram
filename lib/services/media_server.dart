import 'dart:io';

import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../core/errors.dart';
import '../core/media_url.dart';

class UploadedMedia {
  const UploadedMedia({required this.ref, required this.thumbRef});

  /// `tg:<handle>`
  final String ref;

  /// `tgt:<handle>` or '' when the server has no thumbnail.
  final String thumbRef;
}

/// Talks to the media server (which stores everything in a private Telegram
/// channel). The Telegram bot token never reaches the app.
class MediaServer {
  MediaServer._();
  static final MediaServer instance = MediaServer._();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(minutes: 3),
      sendTimeout: const Duration(minutes: 15),
    ),
  );

  Future<String> _token() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw const MediaException('Please log in again.');
    return await user.getIdToken() ?? '';
  }

  void _requireConfigured() {
    if (!mediaServerConfigured) {
      throw const MediaException(
        'The media server address is not set. Run: bash tools/set_media_url.sh',
      );
    }
  }

  Future<UploadedMedia> uploadImage(File file) =>
      _upload(file: file, kind: 'image');

  Future<UploadedMedia> uploadVideo({
    required File file,
    File? thumb,
    required int duration,
    required int width,
    required int height,
    void Function(double progress)? onProgress,
  }) => _upload(
    file: file,
    kind: 'video',
    thumb: thumb,
    duration: duration,
    width: width,
    height: height,
    onProgress: onProgress,
  );

  Future<UploadedMedia> _upload({
    required File file,
    required String kind,
    File? thumb,
    int duration = 0,
    int width = 0,
    int height = 0,
    void Function(double progress)? onProgress,
  }) async {
    _requireConfigured();
    if (!await file.exists()) {
      throw const MediaException(
        'Could not read the selected file. Pick it again.',
      );
    }
    final form = FormData.fromMap({
      'kind': kind,
      'duration': duration,
      'width': width,
      'height': height,
      'file': await MultipartFile.fromFile(
        file.path,
        filename: kind == 'video' ? 'upload.mp4' : 'upload.jpg',
      ),
      if (thumb != null && await thumb.exists())
        'thumb': await MultipartFile.fromFile(
          thumb.path,
          filename: 'thumb.jpg',
        ),
    });
    final res = await _dio.post<Map<String, dynamic>>(
      '$mediaBase/upload',
      data: form,
      options: Options(headers: {'Authorization': 'Bearer ${await _token()}'}),
      onSendProgress: (sent, total) {
        if (total > 0) onProgress?.call(sent / total);
      },
    );
    final data = res.data ?? const {};
    final handle = data['handle'];
    if (handle is! String || handle.isEmpty) {
      throw const MediaException('The media server sent an unexpected answer.');
    }
    return UploadedMedia(
      ref: 'tg:$handle',
      thumbRef: data['thumb'] == true ? 'tgt:$handle' : '',
    );
  }

  /// Best effort: removes the file from the channel. Never throws.
  Future<void> deleteQuietly(String? ref) async {
    if (ref == null || !ref.startsWith('tg:') || !mediaServerConfigured) return;
    try {
      await _dio.delete<void>(
        '$mediaBase/m/${ref.substring(3)}',
        options: Options(
          headers: {'Authorization': 'Bearer ${await _token()}'},
        ),
      );
    } catch (_) {
      // already gone / server offline: ignore
    }
  }
}
