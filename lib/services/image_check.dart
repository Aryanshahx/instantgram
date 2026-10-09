import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:video_compress/video_compress.dart';

import '../core/errors.dart';
import 'video_frames.dart';

/// The photo check model (MobileNet V2 from GantMan/nsfw_model, MIT). It lives in the
/// repository and is downloaded once, the first time somebody uploads.
const String kNsfwModelUrl =
    'https://raw.githubusercontent.com/Aryanshahx/instantgram/main/models/nsfw_mobilenet_v2_q.tflite';
const int kNsfwModelBytes = 4723008;
const int kNsfwInput = 224;

/// How long a share waits for the first download before the photos go up unchecked.
const Duration kModelWait = Duration(seconds: 25);

/// What the model thinks of one picture (the five numbers add up to 1).
class ImageScores {
  const ImageScores({
    this.drawings = 0,
    this.hentai = 0,
    this.neutral = 1,
    this.porn = 0,
    this.sexy = 0,
  });

  factory ImageScores.fromList(List<double> v) => ImageScores(
    drawings: v[0],
    hentai: v[1],
    neutral: v[2],
    porn: v[3],
    sexy: v[4],
  );

  final double drawings, hentai, neutral, porn, sexy;

  /// Nudity or sex (photo or drawn).
  double get explicit => porn + hentai;

  /// Blurred with "Tap to view". Only nudity counts: swimwear and gym photos (the
  /// model's "sexy") stay as they are.
  bool get sensitive => explicit >= 0.6;

  /// Very likely nudity: also goes to the admin panel's Review tab.
  bool get review => explicit >= 0.85;

  /// Not allowed as a profile photo or cover.
  bool get badAvatar => explicit >= 0.75;
}

/// The result for everything in one upload (the worst picture counts).
class ImageVerdict {
  const ImageVerdict({
    required this.checked,
    this.explicit = 0,
    this.sexy = 0,
    this.sensitive = false,
    this.review = false,
  });

  static const skipped = ImageVerdict(checked: false);

  factory ImageVerdict.of(Iterable<ImageScores> all) {
    var v = const ImageVerdict(checked: true);
    for (final s in all) {
      v = ImageVerdict(
        checked: true,
        explicit: math.max(v.explicit, s.explicit),
        sexy: math.max(v.sexy, s.sexy),
        sensitive: v.sensitive || s.sensitive,
        review: v.review || s.review,
      );
    }
    return v;
  }

  /// false: the model could not run (no internet for the first download...).
  final bool checked;
  final double explicit;
  final double sexy;
  final bool sensitive;
  final bool review;

  /// Saved on the post or moment. The admin panel reads `nsfw` and `imgCheck`.
  Map<String, Object> toFields() => {
    'imgCheck': checked ? 'ok' : 'skipped',
    if (sensitive) 'sensitive': true,
    if (checked && explicit >= 0.3)
      'nsfw': double.parse(explicit.toStringAsFixed(2)),
  };
}

/// One thing to check: a photo, or a video (a few frames of it).
class CheckItem {
  const CheckItem(this.file, {this.video = false, this.durationMs = 0});
  final File file;
  final bool video;
  final int durationMs;
}

/// Tests replace the model with this (null result = could not check).
Future<ImageScores?> Function(Uint8List bytes)? debugImageScorer;

/// Tests replace the video frame grab with this.
Future<Uint8List?> Function(String path, int ms)? debugFrameGrab;

final bool _inTests = Platform.environment.containsKey('FLUTTER_TEST');

/// Frames looked at in a video, in milliseconds.
List<int> checkFrames(int durationMs) {
  if (durationMs <= 0) return const [0];
  return {
    math.min(500, durationMs ~/ 2),
    durationMs ~/ 3,
    durationMs * 2 ~/ 3,
  }.toList();
}

/// Checks photos on the phone before they are shared: nudity is blurred for others
/// ("Tap to view") and very likely nudity goes to the admin panel.
class ImageCheck {
  ImageCheck._();
  static final ImageCheck instance = ImageCheck._();

  Interpreter? _interpreter;
  Future<bool>? _loading;

  File get _modelFile =>
      File('${Directory.systemTemp.path}/instantgram_nsfw_v1.tflite');

  bool get isReady => _interpreter != null || debugImageScorer != null;

  /// Starts the one-time download in the background (opening Create calls this).
  void warmUp() {
    if (isReady) return;
    unawaited(ready());
  }

  /// Downloads (once) and loads the model. False when that is not possible right now.
  Future<bool> ready() {
    if (isReady) return Future.value(true);
    if (_inTests) return Future.value(false); // no downloads in tests
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<bool> _load() async {
    try {
      final f = _modelFile;
      if (!f.existsSync() || f.lengthSync() != kNsfwModelBytes) {
        final part = File('${f.path}.part');
        await Dio().download(
          kNsfwModelUrl,
          part.path,
          options: Options(receiveTimeout: const Duration(minutes: 2)),
        );
        if (part.lengthSync() != kNsfwModelBytes) {
          part.deleteSync();
          return false;
        }
        part.renameSync(f.path);
      }
      _interpreter = Interpreter.fromFile(
        f,
        options: InterpreterOptions()..threads = 2,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Scores one encoded picture (JPEG, PNG, WebP...). Null when it cannot be checked.
  Future<ImageScores?> scoreBytes(Uint8List bytes) async {
    final hook = debugImageScorer;
    if (hook != null) return hook(bytes);
    final it = _interpreter;
    if (it == null) return null;
    try {
      // the phone decodes and shrinks the picture straight to 224 x 224 (squashed,
      // as the model was trained)
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: kNsfwInput,
        targetHeight: kNsfwInput,
      );
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      frame.image.dispose();
      codec.dispose();
      if (data == null) return null;
      final px = data.buffer.asUint8List();
      final input = [
        List.generate(
          kNsfwInput,
          (y) => List.generate(kNsfwInput, (x) {
            final i = (y * kNsfwInput + x) * 4;
            return [px[i] / 255.0, px[i + 1] / 255.0, px[i + 2] / 255.0];
          }),
        ),
      ];
      final output = [List<double>.filled(5, 0)];
      it.run(input, output);
      return ImageScores.fromList(output[0]);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _frame(String path, int ms) async {
    final hook = debugFrameGrab;
    if (hook != null) return hook(path, ms);
    try {
      return await VideoCompress.getByteThumbnail(
        path,
        quality: 70,
        position: framePosition(ms),
      );
    } catch (_) {
      return null;
    }
  }

  /// Checks everything in one upload. [wait] = how long the first download may take.
  Future<ImageVerdict> check(
    List<CheckItem> items, {
    Duration wait = kModelWait,
  }) async {
    if (items.isEmpty) return const ImageVerdict(checked: true);
    final ok = await ready().timeout(wait, onTimeout: () => false);
    if (!ok) return ImageVerdict.skipped;
    final scores = <ImageScores>[];
    for (final item in items) {
      if (item.video) {
        for (final ms in checkFrames(item.durationMs)) {
          final b = await _frame(item.file.path, ms);
          if (b == null) continue;
          final s = await scoreBytes(b);
          if (s != null) scores.add(s);
        }
      } else {
        try {
          final s = await scoreBytes(await item.file.readAsBytes());
          if (s == null) return ImageVerdict.skipped;
          scores.add(s);
        } catch (_) {
          return ImageVerdict.skipped;
        }
      }
    }
    if (scores.isEmpty) return ImageVerdict.skipped;
    return ImageVerdict.of(scores);
  }

  /// A profile photo or cover with nudity is refused (when the check can run).
  Future<void> checkAvatar(File f, {String what = 'profile photo'}) async {
    final v = await check([CheckItem(f)], wait: const Duration(seconds: 15));
    if (v.checked && v.explicit >= 0.75) {
      throw ModerationException(
        'This photo can\'t be used as your $what. Please choose another one.',
      );
    }
  }
}
