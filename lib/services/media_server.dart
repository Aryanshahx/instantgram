import 'dart:io';

import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../core/errors.dart';
import '../core/media_url.dart';

class UploadedMedia {
  const UploadedMedia({required this.ref, required this.thumbRef});

  /// `m:<key>`
  final String ref;

  /// `m:<key>` of the video thumbnail, or '' when there is none.
  final String thumbRef;
}

/// Uploads photos and videos to a Tigris bucket.
///
/// 1. The app asks the signer for a one-time upload link (proves who you are with your
///    Firebase login).
/// 2. The app sends the file straight to the bucket with that link (no size trouble, no middle man).
/// 3. The signer checks the stored file (size and real type) and deletes it if it is wrong.
///
/// The storage keys never reach the app.
class MediaServer {
  MediaServer._();
  static final MediaServer instance = MediaServer._();

  static const _imageExt = {'jpg', 'jpeg', 'png', 'webp', 'gif'};
  static const _videoExt = {'mp4', 'm4v', 'mov', 'webm'};

  final Dio _api = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );

  /// No Authorization header here: the link already carries the permission.
  final Dio _put = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(minutes: 60),
      receiveTimeout: const Duration(minutes: 5),
      responseType: ResponseType.plain,
    ),
  );

  Future<Options> _auth() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw const MediaException('Please log in again.');
    final token = await user.getIdToken() ?? '';
    return Options(headers: {'Authorization': 'Bearer $token'});
  }

  void _requireConfigured() {
    if (!mediaServerConfigured) {
      throw const MediaException(
        'The media service address is not set. Run: bash tools/set_media_url.sh',
      );
    }
  }

  String _ext(File file, String kind) {
    final name = file.path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    final allowed = kind == 'video' ? _videoExt : _imageExt;
    if (allowed.contains(ext)) return ext;
    return kind == 'video' ? 'mp4' : 'jpg';
  }

  Future<UploadedMedia> uploadImage(File file) =>
      _upload(file: file, kind: 'image');

  Future<UploadedMedia> uploadVideo({
    required File file,
    File? thumb,
    void Function(double progress)? onProgress,
  }) =>
      _upload(file: file, kind: 'video', thumb: thumb, onProgress: onProgress);

  Future<UploadedMedia> _upload({
    required File file,
    required String kind,
    File? thumb,
    void Function(double progress)? onProgress,
  }) async {
    _requireConfigured();
    if (!await file.exists()) {
      throw const MediaException(
        'Could not read the selected file. Pick it again.',
      );
    }
    final hasThumb = kind == 'video' && thumb != null && await thumb.exists();

    final sign = await _api.post<Map<String, dynamic>>(
      '$mediaApiBase/sign',
      data: {'kind': kind, 'ext': _ext(file, kind), 'thumb': hasThumb},
      options: await _auth(),
    );
    final s = sign.data ?? const <String, dynamic>{};
    final key = s['key'];
    final url = s['url'];
    if (key is! String || url is! String) {
      throw const MediaException(
        'The media service sent an unexpected answer.',
      );
    }
    final type = s['type'] is String
        ? s['type'] as String
        : 'application/octet-stream';

    // The thumbnail is small and optional: a failure here must not lose the video.
    var thumbRef = '';
    final thumbKey = s['thumbKey'];
    final thumbUrl = s['thumbUrl'];
    if (hasThumb && thumbKey is String && thumbUrl is String) {
      try {
        await _putFile(thumbUrl, thumb, 'image/jpeg');
        await _confirm(thumbKey);
        thumbRef = 'm:$thumbKey';
      } catch (_) {
        thumbRef = '';
      }
    }

    await _putFile(url, file, type, onProgress: onProgress);
    await _confirm(key);
    return UploadedMedia(ref: 'm:$key', thumbRef: thumbRef);
  }

  Future<void> _putFile(
    String url,
    File file,
    String type, {
    void Function(double progress)? onProgress,
  }) async {
    final length = await file.length();
    await _put.put<String>(
      url,
      data: file.openRead(),
      options: Options(
        headers: {
          Headers.contentLengthHeader: length,
          Headers.contentTypeHeader: type,
        },
      ),
      onSendProgress: (sent, total) {
        if (length > 0) onProgress?.call((sent / length).clamp(0.0, 1.0));
      },
    );
  }

  Future<void> _confirm(String key) async {
    await _api.post<Map<String, dynamic>>(
      '$mediaApiBase/confirm',
      data: {'key': key},
      options: await _auth(),
    );
  }

  /// Best effort: removes the files from the bucket. Never throws.
  Future<void> deleteQuietly(String? ref, [String? thumbRef]) async {
    if (!mediaServerConfigured) return;
    final keys = <String>[
      for (final r in [ref, thumbRef])
        if (r != null && r.startsWith('m:')) r.substring(2),
    ];
    if (keys.isEmpty) return;
    try {
      await _api.post<void>(
        '$mediaApiBase/delete',
        data: {'keys': keys},
        options: await _auth(),
      );
    } catch (_) {
      // already gone / offline: ignore
    }
  }
}
