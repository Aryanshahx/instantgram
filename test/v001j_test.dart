// v0.0.1 update: loading shapes (no circles), one drag bar, fast feed after
// an account switch, "Original audio" under the name.
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/services/content_filter.dart';
import 'package:instantgram/core/services/hyper_feed.dart';
import 'package:instantgram/core/services/hyper_intelligence.dart';
import 'package:instantgram/core/services/media_service.dart';
import 'package:instantgram/core/services/music_player.dart';
import 'package:instantgram/core/services/original_audio.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/auth/presentation/permission_gate.dart';
import 'package:instantgram/features/feed/presentation/home_screen.dart';
import 'package:instantgram/features/post/data/upload_queue.dart';
import 'package:instantgram/features/profile/data/famous_index.dart';
import 'package:instantgram/features/reels/data/clips_warmup.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/widgets/async_views.dart';
import 'package:instantgram/shared/widgets/emoji_picker.dart';
import 'package:instantgram/shared/widgets/media_view.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime(2026, 10, 20, 12);

Post _p(String id, {String author = 'amit', Map<String, dynamic>? extra}) =>
    Post.fromMap(id, {
      'authorId': author,
      'authorUsername': author,
      'type': 'clip',
      'mediaUrl': 'https://x/$id.mp4',
      'createdAt': Timestamp.fromDate(_now),
      ...?extra,
    });

List<String> _ids(List<Post> l) => [for (final p in l) p.id]..sort();

/// Old style drag bar inside a sheet (36-38 x 4).
final _ownHandle = find.byWidgetPredicate(
  (w) =>
      w is Container &&
      w.constraints != null &&
      w.constraints!.maxHeight == 4 &&
      (w.constraints!.maxWidth == 36 || w.constraints!.maxWidth == 38),
);

void main() {
  setUpAll(() {
    NetImage.disableCache = true;
    MusicPlayer.disabled = true;
  });

  // ------------------------------------------------------------ skeletons
  group('loading shapes instead of circles', () {
    for (final kind in SkeletonKind.values) {
      testWidgets('${kind.name}: fits a page and a list', (t) async {
        t.view.physicalSize = const Size(1080, 2340);
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        // a page (fixed height)
        await t.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark,
            home: Scaffold(body: LoadingView(kind: kind)),
          ),
        );
        await t.pump(const Duration(milliseconds: 300));
        expect(t.takeException(), isNull);
        expect(find.byType(Shimmer), findsWidgets);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        // a scrolling list (no fixed height)
        await t.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark,
            home: Scaffold(
              body: CustomScrollView(
                slivers: [SliverToBoxAdapter(child: LoadingView(kind: kind))],
              ),
            ),
          ),
        );
        await t.pump(const Duration(milliseconds: 300));
        expect(t.takeException(), isNull);
        expect(find.byType(Shimmer), findsWidgets);
        await t.pumpWidget(const SizedBox());
      });
    }

    testWidgets('the light moves; still when animations are off', (t) async {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: Skeleton())));
      expect(t.binding.hasScheduledFrame, isTrue);
      await t.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: MaterialApp(home: Scaffold(body: Skeleton())),
        ),
      );
      await t.pump();
      expect(t.binding.hasScheduledFrame, isFalse);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('sweep over a cover keeps the cover visible', (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(key: ValueKey('cover'), color: Colors.teal),
              LoadingSweep(),
            ],
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('cover')), findsOneWidget);
      expect(find.byType(LoadingSweep), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });

  // ------------------------------------------------------------ drag bar
  testWidgets('emoji sheet: only the sheet\'s own drag bar', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (c) => Scaffold(
            body: TextButton(
              onPressed: () => showEmojiPicker(c),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.byType(EmojiPickerSheet), findsOneWidget);
    expect(_ownHandle, findsNothing);
    final theme = Theme.of(t.element(find.byType(EmojiPickerSheet)));
    expect(theme.bottomSheetTheme.showDragHandle, isTrue);
  });

  // ------------------------------------------------------------ fast feed
  group('feed after a new account / switch', () {
    final feed = HyperFeed.instance;
    setUp(() {
      HyperFeed.debugNow = () => _now.millisecondsSinceEpoch;
      feed.debugReset();
      ContentFilter.instance.debugSet(me: 'me');
      HyperIntelligence.instance.debugSet();
    });

    test('new account: no "empty" before the extras come', () async {
      final base = StreamController<List<Post>>();
      final parts = StreamController<List<Post>>();
      final got = <List<String>>[];
      final sub = feed
          .discover(base.stream, extraParts: () => parts.stream)
          .listen((l) => got.add(_ids(l)));
      base.add(const []);
      await Future<void>.delayed(Duration.zero);
      expect(got, isEmpty, reason: 'keeps the loading shapes');
      parts.add([_p('t1')]);
      await Future<void>.delayed(Duration.zero);
      expect(got.last, ['t1'], reason: 'each part shows at once');
      parts.add([_p('c1'), _p('t1')]);
      await Future<void>.delayed(Duration.zero);
      expect(got.last, ['c1', 't1']);
      await parts.close();
      await sub.cancel();
      await base.close();
    });

    test('nothing anywhere -> empty after the extras are done', () async {
      final base = StreamController<List<Post>>();
      final parts = StreamController<List<Post>>();
      final got = <List<String>>[];
      final sub = feed
          .discover(base.stream, extraParts: () => parts.stream)
          .listen((l) => got.add(_ids(l)));
      base.add(const []);
      parts.add(const []);
      await Future<void>.delayed(Duration.zero);
      expect(got, isEmpty);
      await parts.close();
      await Future<void>.delayed(Duration.zero);
      expect(got.single, isEmpty);
      await sub.cancel();
      await base.close();
    });

    test('people you follow show at once', () async {
      final base = StreamController<List<Post>>();
      final parts = StreamController<List<Post>>();
      final got = <List<String>>[];
      final sub = feed
          .discover(base.stream, extraParts: () => parts.stream)
          .listen((l) => got.add(_ids(l)));
      base.add([_p('f1', author: 'riya')]);
      await Future<void>.delayed(Duration.zero);
      expect(got.last, ['f1']);
      await sub.cancel();
      await parts.close();
      await base.close();
    });

    test('parts: each when ready, errors skipped, then done', () async {
      final slow = Completer<List<Post>>();
      final got = <List<String>>[];
      var done = false;
      partsStream([
        Future.value([_p('a')]),
        Future<List<Post>>.error(StateError('offline')),
        slow.future,
      ]).listen((l) => got.add(_ids(l)), onDone: () => done = true);
      await Future<void>.delayed(Duration.zero);
      expect(got, [
        ['a'],
      ]);
      expect(done, isFalse);
      slow.complete([_p('b')]);
      await Future<void>.delayed(Duration.zero);
      expect(got.last, ['b']);
      expect(done, isTrue);
      var emptyDone = false;
      partsStream(const []).listen((_) {}, onDone: () => emptyDone = true);
      await Future<void>.delayed(Duration.zero);
      expect(emptyDone, isTrue);
    });

    test('famous people are kept when the app part stops', () {
      FamousIndex.instance.debugSet(['star1', 'star2']);
      FamousIndex.instance.stop();
      expect(FamousIndex.instance.ids.value, ['star1', 'star2']);
      expect(FamousIndex.instance.isFamous('star2'), isTrue);
    });

    test('clips list: not running -> answers at once', () async {
      final l = await ClipsWarmup.instance.first();
      expect(l, isA<List<Post>>());
    });

    testWidgets('allowed once -> the next account opens at once', (t) async {
      addTearDown(() {
        PermissionGate.debugCheck = null;
        PermissionGate.debugReset();
      });
      PermissionGate.debugReset();
      PermissionGate.debugCheck = () async =>
          (notifications: true, lockScreen: true);
      await t.pumpWidget(
        const MaterialApp(
          home: PermissionGate(key: ValueKey('a'), child: Text('APP A')),
        ),
      );
      expect(find.text('APP A'), findsNothing, reason: 'first check');
      expect(find.byType(Shimmer), findsWidgets, reason: 'no circle');
      await t.pump();
      expect(find.text('APP A'), findsOneWidget);
      // switch: a new gate; the check never answers -> still opens
      final never = Completer<({bool notifications, bool lockScreen})>();
      PermissionGate.debugCheck = () => never.future;
      await t.pumpWidget(
        const MaterialApp(
          home: PermissionGate(key: ValueKey('b'), child: Text('APP B')),
        ),
      );
      expect(find.text('APP B'), findsOneWidget);
      // a later "not allowed" answer still shows the page
      never.complete((notifications: false, lockScreen: true));
      await t.pump();
      await t.pump();
      expect(find.text('APP B'), findsNothing);
      await t.pumpWidget(const SizedBox());
    });
  });

  // ------------------------------------------------------------ audio
  group('original audio', () {
    test('post: label, page, shown', () {
      final orig = _p('p1', extra: {'musicId': 'o_p1'});
      expect(orig.hasMusic, isFalse);
      expect(orig.hasOriginalAudio, isTrue);
      expect(orig.showsAudio, isTrue);
      expect(orig.hasAudioPage, isTrue);
      expect(orig.audioLabel, 'Original audio');
      final song = _p(
        'p2',
        extra: {
          'audioUrl': 'https://x/s.mp3',
          'audioName': 'Sunny Road',
          'musicId': 'es_1',
        },
      );
      expect(song.showsAudio, isTrue);
      expect(song.hasOriginalAudio, isFalse);
      expect(song.audioLabel, 'Sunny Road');
      final phone = _p('p3', extra: {'audioUrl': 'https://x/a.m4a'});
      expect(phone.showsAudio, isTrue);
      expect(phone.hasAudioPage, isFalse, reason: 'older post, no page');
      expect(phone.audioLabel, 'Music');
      final plain = _p('p4');
      expect(plain.showsAudio, isFalse);
      expect(plain.hasAudioPage, isFalse);
    });

    test('only for videos without music, sound on, not moments', () {
      bool w({
        bool moment = false,
        bool music = false,
        bool video = true,
        bool muted = false,
      }) => OriginalAudio.wanted(
        isMoment: moment,
        hasMusic: music,
        isVideo: video,
        muted: muted,
      );
      expect(w(), isTrue);
      expect(w(moment: true), isFalse);
      expect(w(music: true), isFalse);
      expect(w(video: false), isFalse);
      expect(w(muted: true), isFalse);
    });

    test('phone copies only the played part (trim + cuts)', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const ch = MethodChannel('instantgram/vision');
      MethodCall? got;
      var ms = 12000;
      messenger.setMockMethodCallHandler(ch, (c) async {
        got = c;
        return {'path': '/tmp/orig.m4a', 'durationMs': ms};
      });
      OriginalAudio.debugAndroid = true;
      addTearDown(() {
        OriginalAudio.debugAndroid = false;
        messenger.setMockMethodCallHandler(ch, null);
      });
      const edits = VideoEdits(
        trimStartMs: 1000,
        trimEndMs: 20000,
        cuts: [VideoCut(4000, 5000), VideoCut(8000, 9500)],
      );
      final r = await OriginalAudio.extract('/v.mp4', edits);
      expect(got!.method, 'extractAudio');
      final a = got!.arguments as Map;
      expect(a['path'], '/v.mp4');
      expect(a['startMs'], 1000);
      expect(a['endMs'], 20000);
      expect(a['cuts'], [4000, 5000, 8000, 9500]);
      expect(r!.path, '/tmp/orig.m4a');
      expect(r.durationMs, 12000);
      // under a second: no page
      ms = 600;
      expect(await OriginalAudio.extract('/v.mp4', edits), isNull);
      // no sound / not AAC
      messenger.setMockMethodCallHandler(ch, (c) async => null);
      expect(await OriginalAudio.extract('/v.mp4', edits), isNull);
      // phone error -> post without it
      messenger.setMockMethodCallHandler(
        ch,
        (c) async => throw PlatformException(code: 'vision'),
      );
      expect(await OriginalAudio.extract('/v.mp4', edits), isNull);
    });

    test('upload queue keeps the uploaded sound (resume)', () {
      final t =
          UploadTask(
              id: 'u1',
              kind: UploadTask.clip,
              items: [
                QueuedMedia(path: '/v.mp4', isVideo: true, durationMs: 9000),
              ],
            )
            ..orig = const UploadedMedia(
              url: 'https://x/a.m4a',
              key: 'audio/me/a.m4a',
            )
            ..origMs = 8800;
      final back = UploadTask.fromJson(t.toJson())!;
      expect(back.orig?.url, 'https://x/a.m4a');
      expect(back.orig?.key, 'audio/me/a.m4a');
      expect(back.origMs, 8800);
    });

    testWidgets('line under the name: song name / "Original audio"', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Column(
              children: [
                AudioLine(post: _p('p1', extra: {'musicId': 'o_p1'})),
                AudioLine(
                  post: _p('p3', extra: {'audioUrl': 'https://x/a.m4a'}),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Original audio'), findsOneWidget);
      expect(find.byKey(const ValueKey('post-audio-p1')), findsOneWidget);
      // no page -> just the name, nothing to tap
      expect(find.text('Music'), findsOneWidget);
      expect(find.byKey(const ValueKey('post-audio-p3')), findsNothing);
    });
  });
}
