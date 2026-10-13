import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/navigation/page_cover.dart';
import 'package:instantgram/core/services/background_upload.dart';
import 'package:instantgram/core/services/gif_search.dart';
import 'package:instantgram/core/services/api_client.dart';
import 'package:instantgram/core/services/media_prefetch.dart';
import 'package:instantgram/core/services/media_service.dart';
import 'package:instantgram/core/services/mp4_faststart.dart';
import 'package:instantgram/core/services/uploader.dart';
import 'package:instantgram/core/services/video_cache.dart';
import 'package:instantgram/core/services/video_prep.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/post/data/post_repository.dart';
import 'package:instantgram/features/post/data/upload_queue.dart';
import 'package:instantgram/features/post/presentation/comments_sheet.dart';
import 'package:instantgram/features/post/presentation/gif_picker.dart';
import 'package:instantgram/features/post/presentation/upload_banner.dart';
import 'package:instantgram/features/reels/presentation/clips_screen.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/widgets/bounce.dart';
import 'package:instantgram/shared/widgets/media_view.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:instantgram/shared/widgets/seek_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

// ------------------------------------------------------------ helpers

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark,
  navigatorObservers: [PageCover.instance],
  home: Scaffold(body: child),
);

Post _post({String id = 'p1', String authorId = 'author'}) => Post(
  id: id,
  authorId: authorId,
  authorUsername: 'author',
  authorPhotoUrl: '',
  type: Post.clip,
  mediaUrl: 'https://x.test/a.jpg',
  mediaKey: '',
  caption: '',
  aspectRatio: 1,
  likesCount: 0,
  commentsCount: 0,
  repostsCount: 0,
  viewsCount: 0,
  pinned: false,
  createdAt: DateTime(2026, 1, 1),
);

Comment _c(
  String id, {
  String parent = '',
  String text = 'hi',
  String author = 'bob',
  int likes = 0,
  String gif = '',
}) => Comment(
  id: id,
  authorId: author,
  authorUsername: author,
  authorPhotoUrl: '',
  text: text,
  createdAt: DateTime(2026, 1, 1),
  parentId: parent,
  likesCount: likes,
  gifUrl: gif,
  gifW: 200,
  gifH: 100,
);

/// Big-endian MP4 box.
Uint8List _box(String type, List<int> body) {
  final b = BytesBuilder();
  final size = ByteData(4)..setUint32(0, body.length + 8);
  b.add(size.buffer.asUint8List());
  b.add(ascii.encode(type));
  b.add(body);
  return b.toBytes();
}

Uint8List _stco(List<int> offsets) {
  final d = ByteData(8 + offsets.length * 4);
  d.setUint32(4, offsets.length);
  for (var i = 0; i < offsets.length; i++) {
    d.setUint32(8 + i * 4, offsets[i]);
  }
  return _box('stco', d.buffer.asUint8List());
}

class _FakeVideo extends VideoPlayerController {
  _FakeVideo(Duration length)
    : super.networkUrl(Uri.parse('https://x.test/v.mp4')) {
    value = VideoPlayerValue(
      duration: length,
      isInitialized: true,
      size: const Size(1080, 1920),
    );
  }

  @override
  Future<void> seekTo(Duration position) async =>
      value = value.copyWith(position: position);

  @override
  Future<void> play() async => value = value.copyWith(isPlaying: true);

  @override
  Future<void> pause() async => value = value.copyWith(isPlaying: false);

  @override
  // ignore: must_call_super
  Future<void> dispose() async {}
}

class _CoverProbe extends StatefulWidget {
  const _CoverProbe({required this.log});
  final List<bool> log;

  @override
  State<_CoverProbe> createState() => _CoverProbeState();
}

class _CoverProbeState extends State<_CoverProbe> with PageCoverAware {
  @override
  void onPageCoverChanged(bool covered) => widget.log.add(covered);

  @override
  Widget build(BuildContext context) => const Text('probe');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    kDisableVideoPlayback = true;
    NetImage.disableCache = true;
    MediaPrefetch.disabled = true;
    VideoPool.disabled = true;
    VideoPrep.disabled = true;
    VideoCache.disabled = true;
    BackgroundUpload.disabled = true;
  });

  // ------------------------------------------------------------ HD plan
  group('video prep', () {
    test('4K 60fps -> 1080p 30fps', () {
      final p = VideoPrep.planHd(
        width: 3840,
        height: 2160,
        bitrate: 40000000,
        fps: 60,
      );
      expect(p.compress, isTrue);
      expect((p.width, p.height), (1920, 1080));
      expect(p.fps, 30);
      expect(p.mbps, VideoPrep.hdMbps);
    });

    test('small light video is uploaded as it is', () {
      final p = VideoPrep.planHd(
        width: 720,
        height: 1280,
        bitrate: 3000000,
        fps: 30,
      );
      expect(p.compress, isFalse);
    });

    test('1080p but heavy -> same size, less bitrate', () {
      final p = VideoPrep.planHd(
        width: 1080,
        height: 1920,
        bitrate: 20000000,
        fps: 30,
      );
      expect(p.compress, isTrue);
      expect(p.keepSize, isTrue);
      expect(p.mbps, inInclusiveRange(2, VideoPrep.hdMbps));
    });

    test('scaleTo keeps shape with even numbers', () {
      expect(VideoPrep.scaleTo(1920, 1080, 1080), (1920, 1080));
      expect(VideoPrep.scaleTo(2160, 3840, 1080), (1080, 1920));
      final (w, h) = VideoPrep.scaleTo(1001, 3001, 540);
      expect(w.isEven && h.isEven, isTrue);
      expect(w, 540);
    });
  });

  // ------------------------------------------------------------ resume
  group('resume', () {
    test('PartState survives json', () {
      final s = PartState(
        key: 'clip/u/a.mp4',
        uploadId: 'up1',
        publicUrl: 'https://x/a.mp4',
        partSize: 5 << 20,
        size: 12 << 20,
        etags: {1: '"e1"', 3: '"e3"'},
      );
      final back = PartState.fromJson(jsonDecode(jsonEncode(s.toJson())))!;
      expect(back.key, s.key);
      expect(back.uploadId, 'up1');
      expect(back.etags, {1: '"e1"', 3: '"e3"'});
      expect(PartState.fromJson(null), isNull);
      expect(PartState.fromJson('bad'), isNull);
    });
  });

  // ------------------------------------------------------------ faststart
  group('mp4 fast start', () {
    test('moves the index in front and fixes chunk offsets', () async {
      final dir = await Directory.systemTemp.createTemp('fs');
      final ftyp = _box('ftyp', ascii.encode('isom0000isom'));
      final data = List<int>.generate(100, (i) => i);
      final mdat = _box('mdat', data);
      final first = ftyp.length + 8; // first byte of the video data
      final moov = _box(
        'moov',
        _box(
          'trak',
          _box(
            'mdia',
            _box('minf', _box('stbl', _stco([first, first + 50]))),
          ),
        ),
      );
      final f = File('${dir.path}/in.mp4')
        ..writeAsBytesSync([...ftyp, ...mdat, ...moov]);
      expect(await Mp4FastStart.isFastStart(f), isFalse);

      final out = await Mp4FastStart.process(f);
      expect(out, isNotNull);
      expect(await Mp4FastStart.isFastStart(out!), isTrue);
      final bytes = out.readAsBytesSync();
      expect(bytes.length, f.lengthSync());
      // offsets moved by the index size and still point at the data
      final i = _indexOf(bytes, ascii.encode('stco'));
      final bd = ByteData.sublistView(bytes);
      final o1 = bd.getUint32(i + 4 + 8);
      final o2 = bd.getUint32(i + 4 + 12);
      expect(o1, first + moov.length);
      expect(bytes[o1], 0);
      expect(bytes[o2], 50);
      // already fast start -> nothing to do
      expect(await Mp4FastStart.process(out), isNull);
      await dir.delete(recursive: true);
    });

    test('not an mp4 -> left alone', () async {
      final dir = await Directory.systemTemp.createTemp('fs');
      final f = File('${dir.path}/x.mp4')..writeAsBytesSync([1, 2, 3, 4, 5]);
      expect(await Mp4FastStart.process(f), isNull);
      await dir.delete(recursive: true);
    });
  });

  // ------------------------------------------------------------ cache
  group('video cache', () {
    test('serves ranges and keeps what it downloaded', () async {
      VideoCache.disabled = false;
      final previous = HttpOverrides.current;
      HttpOverrides.global = null;
      final body = Uint8List.fromList(
        List<int>.generate(300000, (i) => i % 251),
      );
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var hits = 0;
      origin.listen((req) async {
        hits++;
        final r = VideoCache.parseRange(req.headers.value('range'));
        final res = req.response;
        res.headers.set('accept-ranges', 'bytes');
        if (r == null) {
          res.contentLength = body.length;
          res.add(body);
        } else {
          final end = r.$2 ?? body.length - 1;
          res.statusCode = HttpStatus.partialContent;
          res.headers.set(
            'content-range',
            'bytes ${r.$1}-$end/${body.length}',
          );
          res.contentLength = end - r.$1 + 1;
          res.add(body.sublist(r.$1, end + 1));
        }
        await res.close();
      });
      final dir = await Directory.systemTemp.createTemp('vc');
      final cache = VideoCache.instance;
      try {
        await cache.start(dir: dir);
        final remote = 'http://127.0.0.1:${origin.port}/v.mp4';
        final local = cache.url(remote);
        expect(local, startsWith('http://127.0.0.1:'));
        final client = HttpClient();
        Future<List<int>> get(String range) async {
          final req = await client.getUrl(Uri.parse(local));
          req.headers.set('range', range);
          final res = await req.close();
          final out = <int>[];
          await for (final c in res) {
            out.addAll(c);
          }
          return out;
        }

        final all = await get('bytes=0-');
        expect(all.length, body.length);
        expect(all, body);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(await cache.isCached(remote), isTrue);
        final before = hits;
        final mid = await get('bytes=1000-1999');
        expect(mid, body.sublist(1000, 2000));
        expect(hits, before, reason: 'watching again = from the phone');
        client.close(force: true);
      } finally {
        await cache.stop();
        await origin.close(force: true);
        await dir.delete(recursive: true);
        HttpOverrides.global = previous;
        VideoCache.disabled = true;
      }
    });

    test('off = plays the normal link', () {
      expect(
        VideoCache.instance.url('https://x.test/a.mp4'),
        'https://x.test/a.mp4',
      );
    });
  });

  // ------------------------------------------------------------ queue
  group('upload queue', () {
    setUp(() => UploadQueue.instance.debugReset());
    tearDown(() => UploadQueue.debugRunner = null);

    test('task survives json (resume after restart)', () {
      final t = UploadTask(
        id: 't1',
        kind: UploadTask.clip,
        caption: 'hello #goa',
        options: const PostOptions(audience: Audience.followers),
        items: [
          QueuedMedia(
              path: '/x/v.mp4',
              isVideo: true,
              aspectRatio: 0.56,
              durationMs: 12000,
            )
            ..hdDone = true
            ..hdPath = '/y/v_hd.mp4'
            ..main = const UploadedMedia(url: 'https://x/m.mp4', key: 'k')
            ..lowPart = PartState(
              key: 'k2',
              uploadId: 'u',
              publicUrl: 'https://x/l.mp4',
              partSize: 5,
              size: 9,
              etags: {1: 'a'},
            ),
        ],
        audioPath: '/x/a.mp3',
        audioName: 'Song',
      )..postId = 'pid';
      final back = UploadTask.fromJson(jsonDecode(jsonEncode(t.toJson())))!;
      expect(back.kind, UploadTask.clip);
      expect(back.caption, 'hello #goa');
      expect(back.options.audience, Audience.followers);
      expect(back.postId, 'pid');
      final m = back.items.single;
      expect(m.isVideo, isTrue);
      expect(m.hdPath, '/y/v_hd.mp4');
      expect(m.main?.url, 'https://x/m.mp4');
      expect(m.lowPart?.etags, {1: 'a'});
      expect(back.audioName, 'Song');
      expect(UploadTask.fromJson('junk'), isNull);
    });

    test('runs in the background and reports when done', () async {
      final ran = <String>[];
      UploadQueue.debugRunner = (t) async {
        ran.add(t.kind);
      };
      final done = UploadQueue.instance.finished.first;
      UploadQueue.instance.add(
        kind: UploadTask.post,
        items: [QueuedMedia(path: '/x/a.jpg', isVideo: false)],
      );
      final t = await done.timeout(const Duration(seconds: 3));
      expect(t.status, UploadStatus.done);
      expect(ran, [UploadTask.post]);
      expect(UploadQueue.instance.tasks, isEmpty);
    });

    test('failed upload waits for retry and is saved', () async {
      var calls = 0;
      UploadQueue.debugRunner = (t) async {
        calls++;
        if (calls == 1) throw const UploadRejected('File type not allowed');
      };
      final t = UploadQueue.instance.add(
        kind: UploadTask.moment,
        items: [QueuedMedia(path: '/x/a.jpg', isVideo: false)],
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(t.status, UploadStatus.failed);
      expect(t.error, contains('not allowed'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('upload_queue_v1'), contains('"failed"'));
      final done = UploadQueue.instance.finished.first;
      UploadQueue.instance.retry(t);
      await done.timeout(const Duration(seconds: 3));
      expect(calls, 2);
      expect(prefs.getString('upload_queue_v1'), isNull);
    });

    test('saved tasks go on at app start', () async {
      final saved = UploadTask(
        id: 'old',
        kind: UploadTask.clip,
        items: [QueuedMedia(path: '/x/v.mp4', isVideo: true)],
      );
      SharedPreferences.setMockInitialValues({
        'upload_queue_v1': jsonEncode([saved.toJson()]),
      });
      final ran = <String>[];
      UploadQueue.debugRunner = (t) async => ran.add(t.id);
      final done = UploadQueue.instance.finished.first;
      await UploadQueue.instance.start();
      await done.timeout(const Duration(seconds: 3));
      expect(ran, ['old']);
    });

    testWidgets('banner: progress, failed -> retry, remove', (t) async {
      final gate = Completer<void>();
      UploadQueue.debugRunner = (task) => gate.future;
      final task = UploadQueue.instance.add(
        kind: UploadTask.clip,
        items: [QueuedMedia(path: '/none/v.mp4', isVideo: true)],
      );
      await t.pumpWidget(_app(const UploadBanner()));
      await t.pump();
      expect(find.byKey(ValueKey('upload-${task.id}')), findsOneWidget);
      expect(find.textContaining('clip'), findsOneWidget);
      gate.completeError(const UploadRejected('Too big'));
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('upload-retry-text')), findsOneWidget);
      expect(find.textContaining('Too big'), findsOneWidget);
      // remove
      await t.tap(find.byKey(const ValueKey('upload-cancel')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('upload-cancel-yes')));
      await t.pumpAndSettle();
      expect(UploadQueue.instance.tasks, isEmpty);
      expect(find.byKey(ValueKey('upload-${task.id}')), findsNothing);
    });
  });

  // ------------------------------------------------------------ clips order
  group('clips order', () {
    test('new clips go to the end, current clip stays', () {
      final a = _post(id: 'a'), b = _post(id: 'b'), c = _post(id: 'c');
      final n = _post(id: 'new');
      final out = stableMerge([a, b, c], [n, a, b, c], keepUpTo: 1);
      expect(out.map((p) => p.id), ['a', 'b', 'c', 'new']);
    });

    test('gone clips are dropped after the current one only', () {
      final a = _post(id: 'a'), b = _post(id: 'b'), c = _post(id: 'c');
      final out = stableMerge([a, b, c], [c], keepUpTo: 1);
      expect(out.map((p) => p.id), ['a', 'b', 'c']);
      final out2 = stableMerge([a, b, c], [a], keepUpTo: 0);
      expect(out2.map((p) => p.id), ['a']);
      expect(stableMerge(const [], [a]).single.id, 'a');
    });
  });

  // ------------------------------------------------------------ seek time
  group('seek bar time', () {
    test('format', () {
      expect(formatVideoTime(0), '0:00');
      expect(formatVideoTime(12400), '0:12');
      expect(formatVideoTime(75000), '1:15');
      expect(formatVideoTime(3725000), '1:02:05');
    });

    testWidgets('shows "0:12 / 0:45" while sliding', (t) async {
      final c = _FakeVideo(const Duration(seconds: 45));
      await t.pumpWidget(
        _app(
          Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 450,
              child: SmoothSeekBar(controller: c),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('seek-time')), findsNothing);
      final bar = find.byKey(const ValueKey('seek-bar'));
      final g = await t.startGesture(t.getTopLeft(bar) + const Offset(20, 9));
      await g.moveBy(const Offset(40, 0));
      await g.moveTo(t.getTopLeft(bar) + const Offset(120, 9));
      await t.pump();
      expect(find.byKey(const ValueKey('seek-time')), findsOneWidget);
      expect(find.text('0:12 / 0:45'), findsOneWidget);
      await g.up();
      await t.pump();
      expect(find.byKey(const ValueKey('seek-time')), findsNothing);
    });
  });

  // ------------------------------------------------------------ bounce
  testWidgets('bounce pops when the value changes', (t) async {
    var liked = false;
    late StateSetter set;
    await t.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, s) {
            set = s;
            return Center(
              child: Bounce(trigger: liked, child: const Icon(Icons.favorite)),
            );
          },
        ),
      ),
    );
    double scale() {
      final tr = t.widget<Transform>(
        find
            .descendant(
              of: find.byType(Bounce),
              matching: find.byType(Transform),
            )
            .first,
      );
      return tr.transform.getMaxScaleOnAxis();
    }

    expect(scale(), 1);
    set(() => liked = true);
    await t.pump();
    await t.pump(const Duration(milliseconds: 140));
    expect(scale(), greaterThan(1.05));
    await t.pumpAndSettle();
    expect(scale(), 1);
  });

  // ------------------------------------------------------------ comments
  group('comments v2', () {
    setUp(() => CommentTile.debugLiked = (id) => Stream.value(id == 'c1'));
    tearDown(() => CommentTile.debugLiked = null);

    test('replies come right after their comment', () {
      final list = threadComments([
        _c('c1'),
        _c('c2'),
        _c('r1', parent: 'c1'),
        _c('r2', parent: 'c2'),
        _c('orphan', parent: 'gone'),
        _c('r3', parent: 'c1'),
      ]);
      expect(list.map((c) => c.id), ['c1', 'r1', 'r3', 'c2', 'r2']);
    });

    test('picture data', () {
      final c = Comment.fromMap('x', {
        'authorId': 'a',
        'text': '',
        'gifUrl': 'https://g/x.webp',
        'gifW': 300,
        'gifH': 150,
        'likesCount': 3,
      });
      expect(c.pictureUrl, 'https://g/x.webp');
      expect(c.pictureAspect, 2);
      expect(c.likesCount, 3);
      expect(c.isReply, isFalse);
      const pic = CommentPicture.gif(url: 'https://g', width: 1, height: 2);
      expect(pic.toMap(), {'gifUrl': 'https://g', 'gifW': 1, 'gifH': 2});
    });

    testWidgets('likes, replies, emoji row, "more replies"', (t) async {
      final ctrl = StreamController<List<Comment>>();
      await t.pumpWidget(
        _app(
          CommentsSheet(post: _post(), stream: ctrl.stream, myUid: 'me'),
        ),
      );
      ctrl.add([
        _c('c1', likes: 4),
        _c('r1', parent: 'c1', text: '@bob one'),
        _c('r2', parent: 'c1'),
        _c('r3', parent: 'c1'),
        _c('c2', gif: 'https://x.test/g.webp'),
      ]);
      await t.pump();
      await t.pump();
      // liked comment shows a red heart + count
      expect(find.byKey(const ValueKey('comment-likes-c1')), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      // 2 replies shown, third behind "View 1 more reply"
      expect(find.byKey(const ValueKey('comment-r1')), findsOneWidget);
      expect(find.byKey(const ValueKey('comment-r3')), findsNothing);
      await t.tap(find.byKey(const ValueKey('more-replies-c1')));
      await t.pump();
      expect(find.byKey(const ValueKey('comment-r3')), findsOneWidget);
      // GIF comment
      await t.dragUntilVisible(
        find.byKey(const ValueKey('comment-pic-c2')),
        find.byType(ListView),
        const Offset(0, -80),
      );
      expect(find.byKey(const ValueKey('comment-pic-c2')), findsOneWidget);
      // emoji row adds to the text
      await t.tap(find.byKey(const ValueKey('emoji-🔥')));
      await t.pump();
      final field = t.widget<TextField>(
        find.byKey(const ValueKey('comment-input')),
      );
      expect(field.controller!.text, '🔥');
      // reply
      await t.ensureVisible(find.byKey(const ValueKey('reply-c2')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('reply-c2')));
      await t.pump();
      expect(find.byKey(const ValueKey('replying-to')), findsOneWidget);
      expect(field.controller!.text, '@bob 🔥');
      await t.tap(find.byTooltip('Cancel reply'));
      await t.pump();
      expect(find.byKey(const ValueKey('replying-to')), findsNothing);
      expect(field.controller!.text, '🔥');
      await ctrl.close();
    });
  });

  // ------------------------------------------------------------ GIFs
  group('gif picker', () {
    tearDown(() => GifSearch.debugPost = null);

    testWidgets('shows GIFs with GIPHY credit', (t) async {
      final asked = <String>[];
      GifSearch.debugPost = (body) async {
        asked.add(body['q'] as String);
        return {
          'gifs': [
            for (var i = 0; i < 4; i++)
              {
                'id': '$i',
                'url': 'https://media.giphy.test/$i.webp',
                'preview': 'https://media.giphy.test/s$i.webp',
                'width': 200,
                'height': 150,
              },
            {'url': 'http://bad'},
          ],
          'next': null,
        };
      };
      PickedGif? got;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async => got = await showGifPicker(context),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(asked, ['']); // trending first
      expect(find.byKey(const ValueKey('giphy-attribution')), findsOneWidget);
      expect(find.byKey(const ValueKey('gif-3')), findsOneWidget);
      expect(find.byKey(const ValueKey('gif-4')), findsNothing); // bad url
      await t.enterText(find.byKey(const ValueKey('gif-search')), 'cat');
      await t.pump(const Duration(milliseconds: 500));
      await t.pumpAndSettle();
      expect(asked.last, 'cat');
      await t.tap(find.byKey(const ValueKey('gif-1')));
      await t.pumpAndSettle();
      expect(got?.gif?.url, 'https://media.giphy.test/1.webp');
    });

    testWidgets('no GIPHY key -> gallery only', (t) async {
      GifSearch.debugPost = (body) async =>
          throw const ApiException('off', statusCode: 503);
      await t.pumpWidget(_app(const GifPickerSheet()));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('gif-off')), findsOneWidget);
      expect(find.text('Choose a GIF'), findsOneWidget);
    });
  });

  // ------------------------------------------------------------ cover
  testWidgets('videos know when a page covers them (not sheets)', (t) async {
    PageCover.instance.debugReset();
    final log = <bool>[];
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [PageCover.instance],
        home: Scaffold(body: _CoverProbe(log: log)),
      ),
    );
    // a sheet (comments) does not pause
    showModalBottomSheet<void>(
      context: nav.currentContext!,
      builder: (_) => const SizedBox(height: 100),
    );
    await t.pumpAndSettle();
    expect(log, isEmpty);
    nav.currentState!.pop();
    await t.pumpAndSettle();
    // moments open as a see-through page -> paused
    nav.currentState!.push(
      PageRouteBuilder<void>(
        opaque: false,
        pageBuilder: (_, a, b) => const SizedBox(),
      ),
    );
    await t.pumpAndSettle();
    expect(log, [true]);
    nav.currentState!.pop();
    await t.pumpAndSettle();
    expect(log, [true, false]);
  });
}

int _indexOf(List<int> hay, List<int> needle) {
  for (var i = 0; i + needle.length <= hay.length; i++) {
    var ok = true;
    for (var k = 0; k < needle.length; k++) {
      if (hay[i + k] != needle[k]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}
