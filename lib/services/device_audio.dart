import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../core/config.dart' show kMaxVideoSeconds;
import '../core/errors.dart';
import '../models/music.dart';
import 'audio_merger.dart';
import 'media_server.dart';

/// Audio from the phone: the user picks a file (mp3, m4a, wav, ogg, flac...), the phone turns
/// the first minute into a small AAC file, and the file is uploaded to the media storage only
/// when the post is shared.
class DeviceAudio {
  DeviceAudio._();

  /// A sound is at most as long as the longest video.
  static const int maxSeconds = kMaxVideoSeconds;

  /// The biggest file that is accepted (it is only read from, never sent as it is).
  static const int maxFileBytes = 200 * 1024 * 1024;

  /// Tests replace this: it returns the file the user picked (null = cancelled).
  static Future<File?> Function()? pickBackend;

  /// Tests replace this: uploads the file and returns its storage reference (`m:<key>`).
  static Future<String> Function(File file)? uploadBackend;

  static Future<File?> pickFile() async {
    final b = pickBackend;
    if (b != null) return b();
    final r = await FilePicker.platform.pickFiles(type: FileType.audio);
    final path = (r == null || r.files.isEmpty) ? null : r.files.first.path;
    return path == null ? null : File(path);
  }

  /// "my_song-01.final.MP3" -> "my song 01.final"
  static String titleOf(String path) {
    var name = path.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    name = name
        .replaceAll(RegExp(r'[_\-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return name.isEmpty ? 'My sound' : name;
  }

  /// Lets the user pick a file and converts it. Returns null when the picker was closed.
  /// Throws a [MediaException] with a readable message when the file cannot be used.
  static Future<MusicTrack?> pick() async {
    final file = await pickFile();
    if (file == null) return null;
    if (!await file.exists()) {
      throw const MediaException('Could not read that file. Pick it again.');
    }
    if (await file.length() > maxFileBytes) {
      throw const MediaException(
        'That audio file is too big (200 MB at most).',
      );
    }
    final r = await AudioMerger.toAac(
      input: file,
      maxSeconds: maxSeconds.toDouble(),
    );
    return MusicTrack.device(
      path: r.file.path,
      title: titleOf(file.path),
      seconds: r.seconds.round(),
    );
  }

  /// Uploads a song from the phone and returns the same song as `my:<storage key>` (what a
  /// post stores). Other tracks are returned as they are.
  static Future<MusicTrack> upload(MusicTrack t) async {
    if (!t.isLocal) return t;
    final file = File(t.localPath);
    final b = uploadBackend;
    final ref = b != null
        ? await b(file)
        : (await MediaServer.instance.uploadVideo(file: file)).ref;
    if (!ref.startsWith('m:')) {
      throw const MediaException('Could not upload the sound.');
    }
    return MusicTrack.uploaded(key: ref.substring(2), title: t.title);
  }
}
