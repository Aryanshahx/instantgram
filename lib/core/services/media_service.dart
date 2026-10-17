import 'net_priority.dart';

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import '../theme/app_colors.dart';
import 'api_client.dart';
import 'uploader.dart';

/// What the file is used for (decides the folder in Tigris + size limits).
/// What a file is for (folder on the server). v0.9: chat photos / GIFs
/// and voice messages.
enum MediaKind {
  post,
  clip,
  story,
  avatar,
  cover,
  thumb,
  audio,
  comment,
  chat,
  voice,
}

/// What the create flow may pick.
enum PickKind {
  /// Posts and clips: any number of photos and videos.
  mixed,

  /// Moments: photos and/or videos (videos up to 60 s).
  moment,
}

/// Music for a post / clip / moment: a file from the phone, or (music
/// update) a song from the library / an AI song / someone's audio
/// ([url] set, nothing to upload).
class PickedAudio {
  const PickedAudio(
    this.file,
    this.name, {
    this.url = '',
    this.musicId = '',
    this.startMs = 0,
    this.durationMs = 0,
  });

  /// A song that is online already (no upload).
  factory PickedAudio.online({
    required String url,
    required String name,
    required String musicId,
    int startMs = 0,
    int durationMs = 0,
  }) => PickedAudio(
    File(''),
    name,
    url: url,
    musicId: musicId,
    startMs: startMs,
    durationMs: durationMs,
  );

  final File file;

  /// Shown to people ("Song · Artist", or the file name).
  final String name;

  /// Online song (music/{musicId}); '' = a file from the phone.
  final String url;
  final String musicId;

  /// Where the song starts (ms).
  final int startMs;

  /// Song length if known (0 = unknown).
  final int durationMs;

  bool get isOnline => url.isNotEmpty;

  /// What the player plays (url or file path).
  String get source => isOnline ? url : file.path;

  PickedAudio withStart(int ms) => PickedAudio(
    file,
    name,
    url: url,
    musicId: musicId,
    startMs: ms < 0 ? 0 : ms,
    durationMs: durationMs,
  );
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

const _imageExts = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp'};

/// Video or photo? Uses the file name, and if that says nothing, the
/// first bytes of the file (some galleries give files without extension).
bool isVideoFile(File file) {
  final path = file.path;
  if (isVideoPath(path)) return true;
  final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
  if (_imageExts.contains(ext)) return false;
  try {
    final raf = file.openSync();
    final head = raf.readSync(16);
    raf.closeSync();
    return isVideoHeader(head);
  } catch (_) {
    return false;
  }
}

/// Video by its first bytes: MP4/MOV/3GP ("ftyp" box, not HEIC/AVIF photos),
/// WebM/MKV, AVI.
bool isVideoHeader(List<int> b) {
  if (b.length >= 12 &&
      b[4] == 0x66 && // f
      b[5] == 0x74 && // t
      b[6] == 0x79 && // y
      b[7] == 0x70) {
    final brand = String.fromCharCodes(b.sublist(8, 12)).toLowerCase();
    const photoBrands = {
      'heic',
      'heix',
      'hevc',
      'heim',
      'heis',
      'mif1',
      'msf1',
      'avif',
      'avis',
    };
    return !photoBrands.contains(brand);
  }
  if (b.length >= 4 &&
      b[0] == 0x1A &&
      b[1] == 0x45 &&
      b[2] == 0xDF &&
      b[3] == 0xA3) {
    return true; // webm / mkv
  }
  if (b.length >= 12 &&
      String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(b.sublist(8, 11)) == 'AVI') {
    return true;
  }
  return false;
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
      return xs.map((x) {
        final f = File(x.path);
        final mime = x.mimeType ?? '';
        final video =
            mime.startsWith('video/') ||
            (!mime.startsWith('image/') && isVideoFile(f));
        return PickedMedia(f, isVideo: video);
      }).toList();
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
    final res = await FilePicker.platform.pickFiles(type: FileType.audio);
    final f = (res == null || res.files.isEmpty) ? null : res.files.first;
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
      final bytes =
          f.bytes ??
          (f.xFile.path.isEmpty ? null : await f.xFile.readAsBytes());
      if (bytes == null) throw StateError('Could not open this file');
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

  /// A GIF from the gallery, unchanged (resizing would stop the
  /// animation). null = cancelled. Throws if it is not a GIF.
  Future<File?> pickGalleryGif() async {
    final x = await _picker.pickImage(
      source: ImageSource.gallery,
      requestFullMetadata: false,
    );
    if (x == null) return null;
    final isGif =
        x.path.toLowerCase().endsWith('.gif') || x.mimeType == 'image/gif';
    if (!isGif) throw const FormatException('Please choose a GIF file');
    return File(x.path);
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

  /// Uploads a file to Tigris (fast + real progress, v0.7):
  /// small files = one direct PUT, big files = parts in parallel.
  ///
  /// v0.8: part uploads can go on later from where they stopped: pass the
  /// saved [resume] state and keep the states given to [onPartState].
  Future<UploadedMedia> upload(
    File file, {
    required MediaKind kind,
    ValueChanged<double>? onProgress,
    PartState? resume,
    ValueChanged<PartState>? onPartState,
  }) async {
    final contentType = contentTypeFor(file.path);
    final size = await file.length();
    onProgress?.call(0);
    var sent = 0;
    void onBytes(int n) {
      sent += n;
      if (size > 0) onProgress?.call((sent / size).clamp(0.0, 0.995));
    }

    UploadedMedia? done;
    if (size >= Uploader.multipartFrom && _multipartWorks) {
      try {
        done = await _uploadParts(
          file,
          kind,
          contentType,
          size,
          onBytes,
          resume: resume,
          onPartState: onPartState,
        );
      } on ApiException catch (e) {
        // old server without /api/multipart -> normal upload
        if (e.statusCode != 404) rethrow;
        _multipartWorks = false;
        sent = 0;
      }
    }
    final UploadedMedia result =
        done ??
        await Uploader.retry<UploadedMedia>((_) async {
          final sign = await ApiClient.instance.post('/api/upload-url', {
            'kind': kind.name,
            'contentType': contentType,
            'size': size,
          });
          await Uploader.put(
            Uri.parse(sign['uploadUrl'] as String),
            file,
            headers: Map<String, String>.from(
              (sign['headers'] as Map?) ?? {'Content-Type': contentType},
            ),
            end: size,
            onBytes: onBytes,
            errorText: _storageError,
          );
          return UploadedMedia(
            url: sign['publicUrl'] as String,
            key: sign['key'] as String,
          );
        });
    onProgress?.call(1);
    return result;
  }

  /// False after the server said it has no multipart upload (old backend).
  static bool _multipartWorks = true;

  /// Big file: 8 MB parts, 4 at a time, each part retried on errors.
  Future<UploadedMedia> _uploadParts(
    File file,
    MediaKind kind,
    String contentType,
    int size,
    void Function(int) onBytes, {
    PartState? resume,
    ValueChanged<PartState>? onPartState,
  }) async {
    PartState? state;
    Map<int, String> urls = {};
    // 1) go on with a saved upload (same file size), if the server still
    //    has it
    if (resume != null && resume.size == size && resume.partSize >= 5 << 20) {
      final missing = [
        for (
          var n = 1;
          n <= Uploader.planParts(size, resume.partSize).length;
          n++
        )
          if (!resume.etags.containsKey(n)) n,
      ];
      try {
        if (missing.isNotEmpty) {
          final r = await ApiClient.instance.post('/api/multipart', {
            'action': 'sign',
            'key': resume.key,
            'uploadId': resume.uploadId,
            'parts': missing,
          });
          final m = (r['partUrls'] as Map?) ?? const {};
          urls = {
            for (final e in m.entries) int.parse('${e.key}'): '${e.value}',
          };
        }
        state = resume;
      } on ApiException catch (e) {
        // old server (no 'sign') or the upload expired -> start again
        debugPrint('resume upload: $e');
      }
    }
    // 2) new upload
    if (state == null) {
      final parts = Uploader.planParts(size);
      final start = await ApiClient.instance.post('/api/multipart', {
        'action': 'create',
        'kind': kind.name,
        'contentType': contentType,
        'size': size,
        'partSize': Uploader.partSize,
        'parts': parts.length,
      });
      final list = (start['partUrls'] as List).cast<String>();
      if (list.length != parts.length) {
        throw const ApiException('Upload failed: server gave wrong parts');
      }
      state = PartState(
        key: start['key'] as String,
        uploadId: start['uploadId'] as String,
        publicUrl: start['publicUrl'] as String,
        partSize: (start['partSize'] as num?)?.toInt() ?? Uploader.partSize,
        size: size,
      );
      urls = {for (var i = 0; i < list.length; i++) i + 1: list[i]};
      onPartState?.call(state);
    }
    final st = state;
    final parts = Uploader.planParts(size, st.partSize);
    // parts already uploaded count as sent
    for (final n in st.etags.keys) {
      if (n >= 1 && n <= parts.length) {
        onBytes(parts[n - 1].$2 - parts[n - 1].$1);
      }
    }
    try {
      await Uploader.pool<void>(Uploader.parallelParts, [
        for (var i = 0; i < parts.length; i++)
          if (!st.etags.containsKey(i + 1))
            () async {
              // v0.13: pull to refresh goes first
              await NetPriority.waitQuiet();
              final url = urls[i + 1];
              if (url == null) {
                throw const ApiException('Upload failed: missing part link');
              }
              final etag = await Uploader.retry(
                (_) => Uploader.put(
                  Uri.parse(url),
                  file,
                  start: parts[i].$1,
                  end: parts[i].$2,
                  onBytes: onBytes,
                  errorText: _storageError,
                ),
              );
              st.etags[i + 1] = etag;
              onPartState?.call(st);
            },
      ]);
      await Uploader.retry(
        (_) => ApiClient.instance.post('/api/multipart', {
          'action': 'complete',
          'key': st.key,
          'uploadId': st.uploadId,
          'parts': [
            for (var n = 1; n <= parts.length; n++)
              {'PartNumber': n, 'ETag': st.etags[n]},
          ],
        }),
      );
      return UploadedMedia(url: st.publicUrl, key: st.key);
    } catch (e) {
      // can go on later -> keep the parts; otherwise free them
      if (onPartState == null) {
        unawaited(
          ApiClient.instance
              .post('/api/multipart', {
                'action': 'abort',
                'key': st.key,
                'uploadId': st.uploadId,
              })
              .then<void>((_) {}, onError: (Object _) {}),
        );
      }
      rethrow;
    }
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

/// Android: use the system Photo Picker. The old gallery mode lists only
/// photos on many phones (videos were missing in create post, clips and
/// moments). The Photo Picker always shows photos AND videos.
void useSystemPhotoPicker() {
  final impl = ImagePickerPlatform.instance;
  if (impl is ImagePickerAndroid) impl.useAndroidPhotoPicker = true;
}
