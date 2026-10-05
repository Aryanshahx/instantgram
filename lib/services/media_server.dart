import 'dart:io';

import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../core/errors.dart';
import '../core/media_url.dart';

class UploadedMedia {
  const UploadedMedia({
    required this.ref,
    required this.thumbRef,
    this.confirmation,
  });

  /// Set when the check of the stored file is still running (see `deferConfirm`); it fails
  /// when the service rejected the file.
  final Future<void>? confirmation;

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

  /// With [deferConfirm] the call returns as soon as the bytes are stored, while the service
  /// still checks the file: [UploadedMedia.confirmation] completes (or fails) later. Chat uses
  /// this to send the message one round trip earlier.
  Future<UploadedMedia> uploadImage(
    File file, {
    void Function(double progress)? onProgress,
    bool deferConfirm = false,
  }) => _upload(
    file: file,
    kind: 'image',
    onProgress: onProgress,
    deferConfirm: deferConfirm,
  );

  DateTime? _warmAt;

  /// Wakes up the media service (it sleeps when unused) and fetches the login token, so the
  /// first upload of a screen does not wait for either. Never throws.
  Future<void> warmUp() async {
    if (!mediaServerConfigured) return;
    final last = _warmAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 4)) {
      return;
    }
    _warmAt = DateTime.now();
    try {
      await FirebaseAuth.instance.currentUser?.getIdToken();
      await _api.get<void>('$mediaApiBase/health');
    } catch (_) {
      _warmAt = null;
    }
  }

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
    bool deferConfirm = false,
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

    // The thumbnail is small and optional: it goes up at the same time as the video, and a
    // failure here must not lose the video.
    final thumbKey = s['thumbKey'];
    final thumbUrl = s['thumbUrl'];
    final Future<String> thumbTask =
        (hasThumb && thumbKey is String && thumbUrl is String)
        ? _uploadThumb(thumb, thumbKey, thumbUrl)
        : Future<String>.value('');

    await _putFile(url, file, type, onProgress: onProgress);
    if (deferConfirm) {
      final check = _confirm(key);
      check.ignore(); // the caller decides what a failure means
      return UploadedMedia(
        ref: 'm:$key',
        thumbRef: await thumbTask,
        confirmation: check,
      );
    }
    await _confirm(key);
    return UploadedMedia(ref: 'm:$key', thumbRef: await thumbTask);
  }

  /// Returns `m:<key>`, or '' when the thumbnail could not be saved. Never throws.
  Future<String> _uploadThumb(File thumb, String key, String url) async {
    try {
      await _putFile(url, thumb, 'image/jpeg');
      await _confirm(key);
      return 'm:$key';
    } catch (_) {
      return '';
    }
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
  Future<void> deleteQuietly(String? ref, [String? thumbRef]) =>
      deleteRefs([?ref, ?thumbRef]);

  /// Same for any number of files (the service takes four at a time).
  Future<void> deleteRefs(List<String> refs) async {
    if (!mediaServerConfigured) return;
    final keys = <String>[
      for (final r in refs)
        if (r.startsWith('m:')) r.substring(2),
    ];
    for (var i = 0; i < keys.length; i += 4) {
      try {
        await _api.post<void>(
          '$mediaApiBase/delete',
          data: {
            'keys': keys.sublist(i, i + 4 > keys.length ? keys.length : i + 4),
          },
          options: await _auth(),
        );
      } catch (_) {
        // already gone / offline: ignore
      }
    }
  }
}
