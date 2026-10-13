import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// Fast, honest uploads (v0.7):
///  * the file is streamed from disk (never fully in memory) and progress
///    counts bytes really handed to the network, so it no longer jumps to
///    100 % and then "hangs" at the end
///  * big videos are split into parts that upload in parallel
///  * a part that fails is retried a few times
class Uploader {
  Uploader._();

  /// Files from this size use the parallel (multipart) upload.
  static int multipartFrom = 10 * 1024 * 1024;

  /// Size of one part (S3 minimum is 5 MB).
  static int partSize = 5 * 1024 * 1024;

  /// Parts uploading at the same time.
  static int parallelParts = 6;

  /// No byte sent for this long = connection is dead -> retry.
  static Duration stallTimeout = const Duration(seconds: 45);

  static const int _tries = 5;

  /// Pause before try 2, 3, 4, 5 (waits for a weak network to come back).
  static List<Duration> retryPauses = const [
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 6),
    Duration(seconds: 12),
  ];

  /// Byte ranges [start, end) of the parts of a file of [size] bytes.
  static List<(int, int)> planParts(int size, [int? part]) {
    final p = part ?? partSize;
    final out = <(int, int)>[];
    for (var s = 0; s < size; s += p) {
      out.add((s, s + p > size ? size : s + p));
    }
    if (out.isEmpty) out.add((0, 0));
    return out;
  }

  /// Runs [tasks] with at most [parallel] at the same time (keeps order).
  static Future<List<T>> pool<T>(
    int parallel,
    List<Future<T> Function()> tasks,
  ) async {
    final results = List<T?>.filled(tasks.length, null);
    var next = 0;
    Future<void> worker() async {
      while (next < tasks.length) {
        final i = next++;
        results[i] = await tasks[i]();
      }
    }

    final n = parallel.clamp(1, tasks.isEmpty ? 1 : tasks.length);
    await Future.wait([for (var i = 0; i < n; i++) worker()]);
    return results.cast<T>();
  }

  /// Retries [task] (network problems) with a short pause between tries.
  static Future<T> retry<T>(
    Future<T> Function(int attempt) task, {
    int tries = _tries,
    void Function()? onRetry,
  }) async {
    for (var a = 1; ; a++) {
      try {
        return await task(a);
      } on UploadRejected {
        rethrow; // storage said no (keys, size...) -> retry won't help
      } catch (e) {
        // the server refused (4xx) -> trying again won't help
        if (e is ApiException && e.statusCode >= 400 && e.statusCode < 500) {
          rethrow;
        }
        if (a >= tries) rethrow;
        onRetry?.call();
        debugPrint('upload retry $a: $e');
        await Future<void>.delayed(
          retryPauses.isEmpty
              ? Duration.zero
              : retryPauses[(a - 1).clamp(0, retryPauses.length - 1)],
        );
      }
    }
  }

  /// PUTs bytes [start, end) of [file] to [url]. Returns the ETag.
  /// [onBytes] gets every chunk size as it goes out ([onBytes] with a
  /// negative number = undo after a failed try).
  static Future<String> put(
    Uri url,
    File file, {
    Map<String, String> headers = const {},
    int start = 0,
    int? end,
    void Function(int bytes)? onBytes,
    String Function(int status, String body)? errorText,
  }) async {
    final stop = end ?? await file.length();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 10);
    var sent = 0;
    Timer? watchdog;
    HttpClientRequest? req;
    void kick() {
      watchdog?.cancel();
      watchdog = Timer(stallTimeout, () {
        req?.abort(const SocketException('Upload stalled'));
      });
    }

    try {
      req = await client.openUrl('PUT', url);
      headers.forEach(
        (k, v) => req!.headers.set(k, v, preserveHeaderCase: true),
      );
      req.contentLength = stop - start;
      req.bufferOutput = false;
      kick();
      await req.addStream(
        file.openRead(start, stop).map((chunk) {
          sent += chunk.length;
          onBytes?.call(chunk.length);
          kick();
          return chunk;
        }),
      );
      final res = await req.close().timeout(const Duration(minutes: 2));
      watchdog?.cancel();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final msg =
            errorText?.call(res.statusCode, body) ??
            'Upload failed (${res.statusCode})';
        // 5xx = storage hiccup (retry); 4xx = real problem
        if (res.statusCode >= 500) throw ApiException(msg);
        throw UploadRejected(msg);
      }
      return (res.headers.value('etag') ?? '').trim();
    } catch (e) {
      if (sent > 0) onBytes?.call(-sent); // progress goes back for the retry
      rethrow;
    } finally {
      watchdog?.cancel();
      client.close(force: true);
    }
  }
}

/// Saved state of a part-by-part upload, so it can go on later from
/// where it stopped (app closed, network gone...).
class PartState {
  PartState({
    required this.key,
    required this.uploadId,
    required this.publicUrl,
    required this.partSize,
    required this.size,
    Map<int, String>? etags,
  }) : etags = etags ?? {};

  final String key;
  final String uploadId;
  final String publicUrl;
  final int partSize;
  final int size;

  /// Part number (1..) -> ETag of the parts already uploaded.
  final Map<int, String> etags;

  Map<String, dynamic> toJson() => {
    'key': key,
    'uploadId': uploadId,
    'publicUrl': publicUrl,
    'partSize': partSize,
    'size': size,
    'etags': {for (final e in etags.entries) '${e.key}': e.value},
  };

  static PartState? fromJson(Object? v) {
    if (v is! Map) return null;
    try {
      final e = v['etags'];
      return PartState(
        key: v['key'] as String,
        uploadId: v['uploadId'] as String,
        publicUrl: v['publicUrl'] as String,
        partSize: (v['partSize'] as num).toInt(),
        size: (v['size'] as num).toInt(),
        etags: e is Map
            ? {
                for (final x in e.entries)
                  int.parse('${x.key}'): '${x.value}',
              }
            : {},
      );
    } catch (_) {
      return null;
    }
  }
}

/// The storage refused the file (wrong keys, too big, ...). Not retried.
class UploadRejected extends ApiException {
  const UploadRejected(super.message);
}
