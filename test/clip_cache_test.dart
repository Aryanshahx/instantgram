import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/services/clip_cache.dart';

/// A tiny file server for the tests: supports Range, can be slow, can ignore Range.
class _Server {
  _Server(this.data, {this.ranges = true, this.chunkDelay = Duration.zero});

  final Uint8List data;
  final bool ranges;
  final Duration chunkDelay;
  late HttpServer server;
  int requests = 0;
  int rangeRequests = 0;
  int active = 0;
  int maxActive = 0;

  String get url => 'http://127.0.0.1:${server.port}/video/u/clip.mp4';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests++;
      if (req.uri.path.contains('missing')) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      active++;
      maxActive = max(maxActive, active);
      try {
        final range = req.headers.value('range');
        if (ranges && range != null) {
          rangeRequests++;
          final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
          final a = int.parse(m.group(1)!);
          final b = min(int.parse(m.group(2)!), data.length - 1);
          req.response.statusCode = 206;
          req.response.headers.set(
            'content-range',
            'bytes $a-$b/${data.length}',
          );
          req.response.headers.contentLength = b - a + 1;
          var p = a;
          while (p <= b) {
            final n = min(64 * 1024, b - p + 1);
            req.response.add(data.sublist(p, p + n));
            await req.response.flush();
            p += n;
            if (chunkDelay > Duration.zero) {
              await Future<void>.delayed(chunkDelay);
            }
          }
        } else {
          req.response.headers.contentLength = data.length;
          var p = 0;
          while (p < data.length) {
            final n = min(64 * 1024, data.length - p);
            req.response.add(data.sublist(p, p + n));
            await req.response.flush();
            p += n;
            if (chunkDelay > Duration.zero) {
              await Future<void>.delayed(chunkDelay);
            }
          }
        }
        await req.response.close();
      } catch (_) {
      } finally {
        active--;
      }
    });
  }

  Future<void> stop() => server.close(force: true);
}

Uint8List _bytes(int n) {
  final r = Random(7);
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('clipcache'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('downloads a clip in pieces over several connections', () async {
    final data = _bytes(5 * 1024 * 1024 + 123);
    final s = _Server(data, chunkDelay: const Duration(milliseconds: 2));
    await s.start();
    addTearDown(s.stop);
    final cache = ClipCache(dir: dir);

    expect(cache.cached(s.url), isNull);
    final f = await cache.prefetch(s.url);
    expect(f, isNotNull);
    expect(f!.readAsBytesSync(), data);
    expect(cache.cached(s.url)?.path, f.path);
    // probe + 6 pieces of 1 MB, fetched in parallel
    expect(s.rangeRequests, greaterThanOrEqualTo(6));
    expect(s.maxActive, greaterThan(1));
    expect(
      dir.listSync().whereType<File>().any((e) => e.path.endsWith('.part')),
      isFalse,
    );

    // a second request is answered from the phone
    final before = s.requests;
    await cache.prefetch(s.url);
    expect(s.requests, before);
  });

  test('small files and files without range support still work', () async {
    final small = _bytes(300 * 1024);
    final a = _Server(small);
    await a.start();
    addTearDown(a.stop);
    final f1 = await ClipCache(dir: dir).prefetch(a.url);
    expect(f1!.readAsBytesSync(), small);

    final dir2 = Directory.systemTemp.createTempSync('clipcache2');
    addTearDown(() => dir2.deleteSync(recursive: true));
    final big = _bytes(2 * 1024 * 1024);
    final b = _Server(big, ranges: false);
    await b.start();
    addTearDown(b.stop);
    final f2 = await ClipCache(dir: dir2).prefetch(b.url);
    expect(f2!.readAsBytesSync(), big);
  });

  test('a missing clip gives null and leaves nothing behind', () async {
    final s = _Server(_bytes(1000));
    await s.start();
    addTearDown(s.stop);
    final f = await ClipCache(dir: dir).prefetch('${s.url}/missing.mp4');
    expect(f, isNull);
    expect(dir.listSync(), isEmpty);
  });

  test('want() cancels downloads that are no longer needed', () async {
    final data = _bytes(6 * 1024 * 1024);
    final s = _Server(data, chunkDelay: const Duration(milliseconds: 40));
    await s.start();
    addTearDown(s.stop);
    final cache = ClipCache(dir: dir);

    cache.want([s.url]);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(cache.isDownloading(s.url), isTrue);
    final pending = cache.inFlight(s.url)!;
    cache.want(const []);
    expect(await pending, isNull);
    expect(cache.cached(s.url), isNull);
    expect(dir.existsSync() ? dir.listSync() : [], isEmpty);
  });

  test('only a few clips are downloaded at the same time, in order', () async {
    final data = _bytes(2 * 1024 * 1024);
    final s = _Server(data, chunkDelay: const Duration(milliseconds: 5));
    await s.start();
    addTearDown(s.stop);
    final cache = ClipCache(dir: dir, connections: 3, parallelClips: 2);
    final urls = [
      for (var i = 0; i < 4; i++)
        '${s.url}?i=$i'.replaceFirst('clip.mp4', 'c$i.mp4'),
    ];
    cache.want(urls);
    final files = await Future.wait(urls.map(cache.prefetch));
    expect(
      files.every((f) => f != null && f.lengthSync() == data.length),
      isTrue,
    );
    // 2 clips x 3 connections at most
    expect(s.maxActive, lessThanOrEqualTo(2 * 3 + 2));
  });
}
