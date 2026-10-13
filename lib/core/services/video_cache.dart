import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

/// Videos are saved on the phone while they play (v0.8):
///  * a tiny server on the phone (127.0.0.1) sits between the player and
///    the storage. Every byte the player downloads is also written to disk
///  * watching again / swiping back = played from the disk (no download)
///  * a half watched video keeps its first part, the rest is downloaded
///    later from where it stopped
///  * [prefetch] downloads the start of the next videos before you get there
///  * old videos are deleted when the cache is bigger than [maxBytes]
class VideoCache {
  VideoCache._();
  static final VideoCache instance = VideoCache._();

  /// Tests switch this off (players get the normal web address).
  static bool disabled = false;

  /// Disk space for videos.
  static int maxBytes = 800 * 1024 * 1024;

  /// How much of the next videos [prefetch] downloads.
  static int prefetchBytes = 1536 * 1024;

  HttpServer? _server;
  Directory? _dir;
  Future<void>? _starting;
  HttpClient? _client;

  /// Files being written right now (one writer per video).
  final Set<String> _writers = {};

  /// Meta data in memory: name -> total size.
  final Map<String, int> _totals = {};

  final LinkedHashSet<String> _prefetched = LinkedHashSet<String>();

  bool get running => _server != null;

  @visibleForTesting
  int originRequests = 0;

  /// Starts the server (safe to call many times).
  Future<void> start({Directory? dir}) {
    if (disabled) return Future.value();
    return _starting ??= _start(dir).catchError((Object e) {
      debugPrint('video cache: $e');
      _starting = null;
    });
  }

  Future<void> _start(Directory? dir) async {
    final base = dir ?? await getApplicationCacheDirectory();
    final d = Directory('${base.path}/video_cache');
    await d.create(recursive: true);
    _dir = d;
    _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 20)
      ..maxConnectionsPerHost = 8;
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen((r) => unawaited(_handle(r)));
    _server = s;
    unawaited(trim());
  }

  /// Stops the server (tests).
  @visibleForTesting
  Future<void> stop() async {
    await _server?.close(force: true);
    _client?.close(force: true);
    _server = null;
    _client = null;
    _starting = null;
    _writers.clear();
    _totals.clear();
    _prefetched.clear();
    originRequests = 0;
  }

  /// Address the player should open for [remote].
  String url(String remote) {
    final s = _server;
    if (s == null || !remote.startsWith('http')) return remote;
    return 'http://127.0.0.1:${s.port}/v/${nameFor(remote)}.mp4'
        '?u=${Uri.encodeComponent(remote)}';
  }

  /// Video player that goes through the cache.
  VideoPlayerController controller(
    String remote, {
    bool mixWithOthers = false,
  }) => VideoPlayerController.networkUrl(
    Uri.parse(url(remote)),
    videoPlayerOptions: VideoPlayerOptions(mixWithOthers: mixWithOthers),
  );

  /// File name for [remote] (64 bit FNV-1a hash, hex).
  @visibleForTesting
  static String nameFor(String remote) {
    var h1 = 0x811c9dc5;
    var h2 = 0x01000193 ^ remote.length;
    for (final c in utf8.encode(remote)) {
      h1 = ((h1 ^ c) * 0x01000193) & 0xffffffff;
      h2 = ((h2 ^ c) * 0x5bd1e995 + 0x2f) & 0xffffffff;
    }
    return h1.toRadixString(16).padLeft(8, '0') +
        h2.toRadixString(16).padLeft(8, '0');
  }

  File _data(String name) => File('${_dir!.path}/$name.data');
  File _meta(String name) => File('${_dir!.path}/$name.meta');

  Future<int?> _total(String name) async {
    final t = _totals[name];
    if (t != null) return t;
    try {
      final v = int.tryParse(await _meta(name).readAsString());
      if (v != null) _totals[name] = v;
      return v;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveTotal(String name, int total) async {
    _totals[name] = total;
    try {
      await _meta(name).writeAsString('$total');
    } catch (_) {}
  }

  Future<int> _have(String name) async {
    try {
      return await _data(name).length();
    } catch (_) {
      return 0;
    }
  }

  /// True when the whole video is on the phone.
  Future<bool> isCached(String remote) async {
    if (_dir == null) return false;
    final n = nameFor(remote);
    final t = await _total(n);
    return t != null && t > 0 && await _have(n) >= t;
  }

  /// Bytes of [remote] saved on the phone.
  Future<int> cachedBytes(String remote) async =>
      _dir == null ? 0 : _have(nameFor(remote));

  // ---------------------------------------------------------------- server

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    var aborted = false;
    unawaited(
      res.done.then<void>((_) {}, onError: (Object _) => aborted = true),
    );
    try {
      final remote = req.uri.queryParameters['u'] ?? '';
      if (!remote.startsWith('http') || _dir == null) {
        res.statusCode = HttpStatus.badRequest;
        await res.close();
        return;
      }
      final name = nameFor(remote);
      final range = parseRange(req.headers.value(HttpHeaders.rangeHeader));
      final a = range?.$1 ?? 0;
      final b = range?.$2; // inclusive, null = to the end
      final have = await _have(name);
      final total = await _total(name);

      // 1) all asked bytes are on the disk
      if (total != null) {
        final end = (b == null || b >= total) ? total - 1 : b;
        if (a > end || a >= total) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
          await res.close();
          return;
        }
        if (end < have) {
          _head(res, range != null, a, end, total);
          if (req.method != 'HEAD') {
            await res.addStream(_data(name).openRead(a, end + 1));
          }
          await res.close();
          _touch(name);
          return;
        }
      }

      // 2) start is on the disk (or right after it): disk + download the
      //    rest, which is saved too
      if (a <= have && !_writers.contains(name) && req.method != 'HEAD') {
        await _diskThenOrigin(req, res, remote, name, a, b, have, total, () {
          return aborted;
        });
        return;
      }

      // 3) somewhere in the middle (or someone else is saving it): just
      //    pass it through
      await _passThrough(req, res, remote, () => aborted);
    } catch (e) {
      debugPrint('video cache: $e');
      try {
        res.statusCode = HttpStatus.badGateway;
        await res.close();
      } catch (_) {}
    }
  }

  void _head(HttpResponse res, bool partial, int a, int end, int total) {
    res.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
    res.headers
      ..contentType = ContentType('video', 'mp4')
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentLength = end - a + 1;
    if (partial) {
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $a-$end/$total');
    }
  }

  Future<HttpClientResponse> _origin(String remote, String? range) async {
    originRequests++;
    final rq = await _client!.getUrl(Uri.parse(remote));
    if (range != null) rq.headers.set(HttpHeaders.rangeHeader, range);
    return rq.close();
  }

  Future<void> _diskThenOrigin(
    HttpRequest req,
    HttpResponse res,
    String remote,
    String name,
    int a,
    int? b,
    int have,
    int? knownTotal,
    bool Function() aborted,
  ) async {
    _writers.add(name);
    RandomAccessFile? out;
    HttpClientResponse? upstream;
    var used = false;
    try {
      // download from the first missing byte
      final from = have;
      final up = upstream = await _origin(remote, 'bytes=$from-${b ?? ''}');
      int? total = knownTotal;
      if (up.statusCode == HttpStatus.partialContent) {
        total = parseTotal(up.headers.value(HttpHeaders.contentRangeHeader));
      } else if (up.statusCode == HttpStatus.ok && from == 0) {
        total = up.contentLength >= 0 ? up.contentLength : null;
      } else if (up.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
          knownTotal == null) {
        // the disk already has everything but no size: ask again normally
        used = true;
        await up.drain<void>();
        _writers.remove(name);
        await _passThrough(req, res, remote, aborted);
        return;
      } else {
        // error from the storage: tell the player
        used = true;
        res.statusCode = up.statusCode;
        await res.addStream(up);
        await res.close();
        return;
      }
      if (total == null || total <= 0) {
        // unknown size: can't answer ranges -> stream without saving
        used = true;
        res.statusCode = up.statusCode;
        res.headers.contentType = ContentType('video', 'mp4');
        await res.addStream(up);
        await res.close();
        return;
      }
      if (knownTotal == null) await _saveTotal(name, total);
      final end = (b == null || b >= total) ? total - 1 : b;
      _head(res, req.headers.value(HttpHeaders.rangeHeader) != null, a, end,
          total);
      // a) the part that is already on the disk
      if (a < have) {
        await res.addStream(_data(name).openRead(a, have));
      }
      // b) the rest: to the player AND to the disk
      final file = out = await _data(name).open(mode: FileMode.append);
      used = true;
      try {
        // addStream waits for the player (no big memory buffer)
        await res.addStream(
          up.asyncMap((chunk) async {
            await file.writeFrom(chunk);
            return chunk;
          }),
        );
      } catch (_) {
        // player closed the connection (swiped away / seek): the part
        // saved so far stays on the disk
      }
      await file.close();
      out = null;
      try {
        await res.close();
      } catch (_) {}
      _touch(name);
      if (await _have(name) >= total) _scheduleTrim();
    } finally {
      try {
        await out?.close();
      } catch (_) {}
      if (!used && upstream != null) {
        // player left before the download started: close it
        unawaited(upstream.listen((_) {}).cancel());
      }
      _writers.remove(name);
    }
  }

  Future<void> _passThrough(
    HttpRequest req,
    HttpResponse res,
    String remote,
    bool Function() aborted,
  ) async {
    final up = await _origin(remote, req.headers.value(HttpHeaders.rangeHeader));
    res.statusCode = up.statusCode;
    res.headers.contentType = ContentType('video', 'mp4');
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    final cr = up.headers.value(HttpHeaders.contentRangeHeader);
    if (cr != null) res.headers.set(HttpHeaders.contentRangeHeader, cr);
    if (up.contentLength >= 0) res.headers.contentLength = up.contentLength;
    try {
      await res.addStream(up);
      await res.close();
    } catch (_) {
      // player closed the connection
    }
  }

  // ---------------------------------------------------------------- prefetch

  /// Downloads the first [bytes] of [remote] (next videos start at once).
  Future<void> prefetch(String remote, {int? bytes}) async {
    if (_dir == null || !remote.startsWith('http')) return;
    final want = bytes ?? prefetchBytes;
    final name = nameFor(remote);
    if (_writers.contains(name)) return;
    final key = '$name:$want';
    if (_prefetched.contains(key)) return;
    _prefetched.add(key);
    if (_prefetched.length > 300) _prefetched.remove(_prefetched.first);
    final have = await _have(name);
    final total = await _total(name);
    if (have >= want || (total != null && have >= total)) return;
    if (_writers.contains(name)) return;
    _writers.add(name);
    RandomAccessFile? out;
    try {
      final up = await _origin(remote, 'bytes=$have-${want - 1}');
      if (up.statusCode != HttpStatus.partialContent &&
          !(up.statusCode == HttpStatus.ok && have == 0)) {
        await up.drain<void>();
        _prefetched.remove(key);
        return;
      }
      final t = up.statusCode == HttpStatus.ok
          ? up.contentLength
          : parseTotal(up.headers.value(HttpHeaders.contentRangeHeader));
      if (t != null && t > 0 && total == null) await _saveTotal(name, t);
      out = await _data(name).open(mode: FileMode.append);
      var got = have;
      await for (final chunk in up) {
        await out.writeFrom(chunk);
        got += chunk.length;
        if (got >= want) break; // 200 = whole file: stop early
      }
    } catch (e) {
      _prefetched.remove(key);
      debugPrint('video prefetch: $e');
    } finally {
      try {
        await out?.close();
      } catch (_) {}
      _writers.remove(name);
    }
  }

  // ---------------------------------------------------------------- cleanup

  void _touch(String name) {
    try {
      _data(name).setLastModifiedSync(DateTime.now());
    } catch (_) {}
  }

  Timer? _trimTimer;
  void _scheduleTrim() {
    _trimTimer?.cancel();
    _trimTimer = Timer(const Duration(seconds: 5), () => unawaited(trim()));
  }

  /// Deletes the oldest videos until the cache fits in [maxBytes].
  Future<void> trim() async {
    final d = _dir;
    if (d == null) return;
    try {
      final files = <(File, int, DateTime)>[];
      var sum = 0;
      await for (final e in d.list()) {
        if (e is! File || !e.path.endsWith('.data')) continue;
        final st = await e.stat();
        files.add((e, st.size, st.modified));
        sum += st.size;
      }
      if (sum <= maxBytes) return;
      files.sort((x, y) => x.$3.compareTo(y.$3));
      for (final f in files) {
        if (sum <= maxBytes * 0.8) break;
        final name = f.$1.uri.pathSegments.last.replaceAll('.data', '');
        if (_writers.contains(name)) continue;
        try {
          await f.$1.delete();
          await _meta(name).delete();
        } catch (_) {}
        _totals.remove(name);
        _prefetched.removeWhere((k) => k.startsWith('$name:'));
        sum -= f.$2;
      }
    } catch (e) {
      debugPrint('video cache trim: $e');
    }
  }

  // ---------------------------------------------------------------- helpers

  /// "bytes=a-b" -> (a, b). b is null for "bytes=a-".
  @visibleForTesting
  static (int, int?)? parseRange(String? h) {
    if (h == null) return null;
    final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(h.trim());
    if (m == null) return null;
    final a = int.tryParse(m.group(1)!);
    final b = int.tryParse(m.group(2)!);
    if (a == null) return null; // "bytes=-500" (suffix) not used by players
    return (a, b);
  }

  /// Total size from "bytes a-b/total".
  @visibleForTesting
  static int? parseTotal(String? contentRange) {
    if (contentRange == null) return null;
    final i = contentRange.lastIndexOf('/');
    if (i < 0) return null;
    return int.tryParse(contentRange.substring(i + 1).trim());
  }
}
