import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';

/// Downloads clips to the phone ahead of time, as fast as the connection allows.
///
/// Each clip is cut into small pieces that are fetched over several connections at once
/// (HTTP Range), so a single slow connection can not hold it back. A clip that was downloaded
/// plays from the phone's storage: it starts at once, never buffers, and loops without using
/// the internet again.
///
/// [want] is called by the Clips screen with the clips that will be needed next. Anything
/// that is no longer needed is cancelled so the whole connection is used for what matters.
class ClipCache {
  ClipCache({Directory? dir, this.connections = 6, this.parallelClips = 2})
    : _dir = dir ?? Directory('${Directory.systemTemp.path}/clip_cache');

  static final ClipCache instance = ClipCache();

  /// Parallel connections used for one clip.
  final int connections;

  /// Clips downloaded at the same time.
  final int parallelClips;

  final Directory _dir;

  /// Cache size limit; the least recently used clips are deleted beyond it.
  static const int maxCacheBytes = 600 * 1024 * 1024;

  /// Biggest clip we download (same as the upload limit).
  static const int maxClipBytes = 320 * 1024 * 1024;

  static const int _segment = 1024 * 1024; // size of one piece

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 40),
      followRedirects: true,
    ),
  );

  final Map<String, _Job> _jobs = {};
  final Queue<String> _queue = Queue<String>();
  int _running = 0;

  String _name(String url) {
    final u = Uri.tryParse(url);
    final raw = u == null ? url : '${u.host}${u.path}';
    final clean = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return clean.length > 140 ? clean.substring(clean.length - 140) : clean;
  }

  File _file(String url) => File('${_dir.path}/${_name(url)}');

  /// The downloaded clip, or null.
  File? cached(String url) {
    final f = _file(url);
    if (f.existsSync() && f.lengthSync() > 0) {
      try {
        f.setLastModifiedSync(DateTime.now()); // "recently used"
      } catch (_) {}
      return f;
    }
    return null;
  }

  /// A download that is running or queued for [url] (completes with the file, or null when it
  /// failed or was cancelled).
  Future<File?>? inFlight(String url) => _live(url)?.done.future;

  bool isDownloading(String url) => _live(url) != null;

  /// Sets the clips to have ready, most important first. Downloads for other clips are
  /// cancelled.
  void want(List<String> urls) {
    final keep = urls.where((u) => u.isNotEmpty).toSet();
    for (final e in _jobs.entries.toList()) {
      if (!keep.contains(e.key)) cancel(e.key);
    }
    _queue.removeWhere((u) => !keep.contains(u));
    for (final u in urls) {
      if (u.isEmpty || cached(u) != null || _live(u) != null) continue;
      _enqueue(u);
    }
    _pump();
  }

  /// Starts (or joins) the download of one clip and returns when it is done.
  Future<File?> prefetch(String url) {
    final have = cached(url);
    if (have != null) return Future.value(have);
    final job = _live(url) ?? _enqueue(url);
    _pump();
    return job.done.future;
  }

  /// A job that is still wanted (a cancelled one that has not finished stopping is ignored).
  _Job? _live(String url) {
    final j = _jobs[url];
    return (j == null || j.token.isCancelled) ? null : j;
  }

  _Job _enqueue(String url) {
    final job = _Job(url);
    _jobs[url] = job;
    _queue.add(url);
    return job;
  }

  /// Stops the download of [url] (a half-downloaded file is deleted).
  void cancel(String url) {
    final job = _jobs[url];
    if (job == null) return;
    _queue.remove(url);
    job.token.cancel('not needed');
    if (!job.started) {
      _jobs.remove(url);
      job.done.complete(null);
    }
  }

  void _pump() {
    while (_running < parallelClips && _queue.isNotEmpty) {
      final url = _queue.removeFirst();
      final job = _jobs[url];
      if (job == null || job.token.isCancelled) continue;
      job.started = true;
      _running++;
      _run(job).whenComplete(() {
        _running--;
        if (identical(_jobs[url], job)) _jobs.remove(url);
        _pump();
      });
    }
  }

  Future<void> _run(_Job job) async {
    File? result;
    try {
      await _dir.create(recursive: true);
      result = await _download(job);
      if (result != null) unawaited(_trim());
    } catch (_) {
      result = null;
    }
    if (!job.done.isCompleted) job.done.complete(result);
  }

  Future<File?> _download(_Job job) async {
    final dest = _file(job.url);
    final part = File('${dest.path}.part');
    RandomAccessFile? raf;
    try {
      // 1) how big is it, and are ranges supported?
      int? total;
      var ranges = false;
      final probe = await _dio.get<ResponseBody>(
        job.url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Range': 'bytes=0-0'},
          validateStatus: (s) => s != null && s < 500,
        ),
        cancelToken: job.token,
      );
      // only the headers matter (a server that ignores Range would send the whole file)
      final sub = probe.data?.stream.listen((_) {});
      await sub?.cancel();
      if (probe.statusCode == 206) {
        final cr = probe.headers.value('content-range'); // bytes 0-0/12345
        final slash = cr?.lastIndexOf('/') ?? -1;
        if (cr != null && slash > 0) {
          total = int.tryParse(cr.substring(slash + 1));
          ranges = total != null && total > 0;
        }
      } else if (probe.statusCode != 200) {
        return null;
      }
      if (total != null && total > maxClipBytes) return null;

      raf = await part.open(mode: FileMode.write);
      var written = 0;

      if (!ranges || total == null) {
        // no range support: one plain download
        final resp = await _dio.get<ResponseBody>(
          job.url,
          options: Options(responseType: ResponseType.stream),
          cancelToken: job.token,
        );
        if (resp.statusCode != 200) return null;
        await for (final chunk in resp.data!.stream) {
          await raf.writeFrom(chunk);
          written += chunk.length;
          if (written > maxClipBytes) throw StateError('too big');
        }
      } else {
        // 2) pieces fetched by several workers at the same time
        final size = total;
        final pieces = <_Piece>[];
        // a few big pieces for small files, 1 MB pieces for large ones
        final seg = size <= _segment * connections
            ? (size / connections).ceil().clamp(64 * 1024, _segment)
            : _segment;
        for (var s = 0; s < size; s += seg) {
          pieces.add(_Piece(s, (s + seg < size ? s + seg : size) - 1));
        }
        var next = 0;
        // writes happen one at a time (one file handle), downloads in parallel
        var writeChain = Future<void>.value();
        final handle = raf;
        Future<void> writeAt(int pos, List<int> data) {
          final f = writeChain.then((_) async {
            await handle.setPosition(pos);
            await handle.writeFrom(data);
          });
          writeChain = f.catchError((_) {});
          return f;
        }

        Future<void> worker() async {
          while (true) {
            if (job.token.isCancelled) return;
            if (next >= pieces.length) return;
            final p = pieces[next++];
            var attempt = 0;
            while (true) {
              try {
                final resp = await _dio.get<ResponseBody>(
                  job.url,
                  options: Options(
                    responseType: ResponseType.stream,
                    headers: {'Range': 'bytes=${p.start}-${p.end}'},
                  ),
                  cancelToken: job.token,
                );
                if (resp.statusCode != 206) throw StateError('no range');
                var pos = p.start;
                await for (final chunk in resp.data!.stream) {
                  await writeAt(pos, chunk);
                  pos += chunk.length;
                }
                if (pos != p.end + 1) throw StateError('short piece');
                break;
              } catch (e) {
                if (job.token.isCancelled || attempt >= 2) rethrow;
                attempt++;
              }
            }
          }
        }

        await Future.wait([for (var i = 0; i < connections; i++) worker()]);
        await writeChain;
        written = size;
      }

      await raf.close();
      raf = null;
      if (job.token.isCancelled) return null;
      if (total != null && await part.length() != total) return null;
      if (await dest.exists()) await dest.delete();
      await part.rename(dest.path);
      return dest;
    } catch (_) {
      return null;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
      if (await part.exists()) {
        try {
          await part.delete();
        } catch (_) {}
      }
    }
  }

  /// Deletes the least recently used clips beyond [maxCacheBytes].
  Future<void> _trim() async {
    try {
      final files = <File>[];
      var sum = 0;
      await for (final e in _dir.list()) {
        if (e is File && !e.path.endsWith('.part')) {
          files.add(e);
          sum += await e.length();
        }
      }
      if (sum <= maxCacheBytes) return;
      final dated = <(File, DateTime)>[
        for (final f in files) (f, await f.lastModified()),
      ]..sort((a, b) => a.$2.compareTo(b.$2));
      for (final (f, _) in dated) {
        if (sum <= maxCacheBytes * 0.8) break;
        final len = await f.length();
        await f.delete();
        sum -= len;
      }
    } catch (_) {}
  }

  /// Deletes every downloaded clip.
  Future<void> clear() async {
    for (final u in _jobs.keys.toList()) {
      cancel(u);
    }
    try {
      if (await _dir.exists()) await _dir.delete(recursive: true);
    } catch (_) {}
  }
}

class _Job {
  _Job(this.url);
  final String url;
  final CancelToken token = CancelToken();
  final Completer<File?> done = Completer<File?>();
  bool started = false;
}

class _Piece {
  _Piece(this.start, this.end);
  final int start;
  final int end;
}
