import 'dart:io';

import 'package:record/record.dart';

import '../core/errors.dart';

/// A finished recording.
class RecordedVoice {
  const RecordedVoice(this.file, this.seconds);
  final File file;
  final int seconds;
}

/// Records a voice note (AAC in an mp4 container, small and plays everywhere).
class VoiceRecorder {
  AudioRecorder? _rec;
  DateTime? _startedAt;
  String? _path;

  static const int maxSeconds = 300;

  bool get recording => _startedAt != null;

  Future<void> start() async {
    final rec = _rec ??= AudioRecorder();
    if (!await rec.hasPermission()) {
      throw const MediaException(
        'Microphone permission is needed. Allow it in the phone settings.',
      );
    }
    final path =
        '${Directory.systemTemp.path}/voice_${DateTime.now().microsecondsSinceEpoch}.m4a';
    await rec.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: path,
    );
    _path = path;
    _startedAt = DateTime.now();
  }

  /// Stops and returns the file (null when [keep] is false or nothing was recorded).
  Future<RecordedVoice?> stop({bool keep = true}) async {
    final rec = _rec;
    final started = _startedAt;
    _startedAt = null;
    if (rec == null || started == null) return null;
    String? out;
    try {
      out = await rec.stop();
    } catch (_) {
      out = null;
    }
    final path = out ?? _path;
    _path = null;
    if (path == null) return null;
    final file = File(path);
    if (!keep || !await file.exists()) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      return null;
    }
    final secs = DateTime.now().difference(started).inSeconds;
    return RecordedVoice(file, secs < 1 ? 1 : secs);
  }

  Future<void> dispose() async {
    await stop(keep: false);
    try {
      await _rec?.dispose();
    } catch (_) {}
    _rec = null;
  }
}
