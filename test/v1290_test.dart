// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/finish.dart';
import 'package:instantgram/models/story.dart';
import 'package:instantgram/screens/post/editor_screen.dart';
import 'package:instantgram/screens/post/video_editor_screen.dart';
import 'package:instantgram/services/giphy.dart';
import 'package:instantgram/services/video_frames.dart';
import 'package:instantgram/widgets/media_layers.dart';
import 'package:instantgram/widgets/overlay_tools.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// A video player that plays nothing: it only reports a 20 second clip, so the editor can be
/// opened in a test.
class _FakePlayer extends VideoPlayerPlatform {
  final _events = StreamController<VideoEvent>.broadcast();
  Duration position = Duration.zero;
  final seeks = <Duration>[];
  bool playing = false;

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose(int playerId) async {}

  @override
  Future<int?> create(DataSource dataSource) async => 1;

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) async* {
    yield VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 20),
      size: const Size(1080, 1920),
    );
    yield* _events.stream;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> play(int playerId) async => playing = true;

  @override
  Future<void> pause(int playerId) async => playing = false;

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> seekTo(int playerId, Duration p) async {
    position = p;
    seeks.add(p);
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => position;

  @override
  Widget buildView(int playerId) => const ColoredBox(color: Colors.blueGrey);

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
}

Future<void> _settle(WidgetTester t, bool Function() done) async {
  for (var i = 0; i < 30 && !done(); i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// A 1x1 PNG.
const _png = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0xF8,
  0xCF,
  0xC0,
  0xF0,
  0x1F,
  0x00,
  0x05,
  0x00,
  0x01,
  0xFF,
  0x89,
  0x99,
  0x3D,
  0x1D,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

/// Alpha (0..255) the chroma matrix gives a colour.
double _alpha(List<double> m, int r, int g, int b) =>
    (m[15] * r + m[16] * g + m[17] * b + m[19]).clamp(0, 255).toDouble();

Future<void> _scrollTo(WidgetTester t, String key) async {
  final scroll = find
      .ancestor(
        of: find.byKey(const ValueKey('tool_audio')),
        matching: find.byType(Scrollable),
      )
      .first;
  await t.dragUntilVisible(
    find.byKey(ValueKey(key)),
    scroll,
    const Offset(-120, 0),
  );
  await t.pump();
}

void main() {
  group('v1.29.0 models', () {
    test('split parts and speed move times to the uploaded clip', () {
      const f = MediaFinish(
        overlays: [
          StoryOverlay(text: 'a', from: 2, to: 4), // in the first part
          StoryOverlay(text: 'b', from: 6, to: 7), // inside the removed part
          StoryOverlay(text: 'c', from: 9, to: 12), // after the gap
          StoryOverlay(text: 'always'),
        ],
        layers: [MediaLayer(ref: 'm:x', from: 4, to: 11)],
      );
      final r = f.retimed(const [(1, 5), (8, 20)], 2);
      expect(r.overlays.map((o) => o.text), ['a', 'c', 'always']);
      expect(r.overlays[0].from, closeTo(0.5, 1e-9)); // (2-1)/2
      expect(r.overlays[0].to, closeTo(1.5, 1e-9));
      expect(r.overlays[1].from, closeTo(2.5, 1e-9)); // (4 + 1)/2
      expect(r.overlays[1].to, closeTo(4, 1e-9));
      expect(r.overlays[2].isAlways, isTrue);
      expect(r.layers.single.from, closeTo(1.5, 1e-9)); // 3/2
      expect(r.layers.single.to, closeTo(3.5, 1e-9)); // (4+3)/2
    });

    test('a plain trim moves times back to the start', () {
      const f = MediaFinish(
        overlays: [StoryOverlay(text: 'x', from: 5, to: 8)],
      );
      final r = f.retimed(const [(4, 10)], 1);
      expect(r.overlays.single.from, closeTo(1, 1e-9));
      expect(r.overlays.single.to, closeTo(4, 1e-9));
      // ends at the end of the clip: shown to the end
      final e = const MediaFinish(
        overlays: [StoryOverlay(text: 'y', from: 5, to: 10)],
      ).retimed(const [(4, 10)], 1);
      expect(e.overlays.single.to, -1);
    });

    test('layers, masks, keys and animations survive saving', () {
      const l = MediaLayer(
        ref: 'm:image/u/abc.jpg',
        aspect: 0.75,
        dx: 0.3,
        dy: 0.6,
        scale: 0.4,
        turns: 0.1,
        opacity: 0.8,
        blend: 'screen',
        chroma: ChromaKey(color: 0xFF00FF00, strength: 0.7, soft: 0.2),
        mask: LayerMask(shape: 'heart', cx: 0.4, size: 0.5, invert: true),
        anim: MotionAnim(inn: 'zoom', out: 'fade', secs: 1),
        from: 1.5,
        to: 6,
      );
      final f = MediaFinish(
        layers: const [l],
        mask: const LayerMask(shape: 'star'),
      );
      final back = MediaFinish.fromMap(f.toMap())!;
      final b = back.layers.single;
      expect(b.ref, l.ref);
      expect(b.blend, 'screen');
      expect(b.blendMode, BlendMode.screen);
      expect(b.chroma!.color, 0xFF00FF00);
      expect(b.chroma!.strength, closeTo(0.7, 1e-9));
      expect(b.mask!.shape, 'heart');
      expect(b.mask!.invert, isTrue);
      expect(b.anim!.inn, 'zoom');
      expect(b.anim!.out, 'fade');
      expect(b.from, 1.5);
      expect(b.to, 6);
      expect(back.mask!.shape, 'star');
      expect(back.animated, isTrue);
      expect(b.isLocal, isFalse);
      expect(const MediaLayer(ref: '/data/x.jpg').isLocal, isTrue);
      // unknown values are dropped
      expect(LayerMask.fromMap({'s': 'blob'}), isNull);
      expect(MediaLayer.fromMap({'u': ''}), isNull);
    });

    test('animations come in and go out', () {
      const a = MotionAnim(inn: 'fade', out: 'zoom', secs: 1);
      final start = motionAt(a, 2, from: 2, to: 6);
      expect(start.opacity, closeTo(0, 0.01));
      final mid = motionAt(a, 4, from: 2, to: 6);
      expect(mid.isRest, isTrue);
      final leaving = motionAt(a, 5.9, from: 2, to: 6);
      expect(leaving.scale, lessThan(0.5));
      // shown to the end: the clip's end counts
      final end = motionAt(a, 9.95, from: 0, clipEnd: 10);
      expect(end.isRest, isFalse);
      expect(motionAt(null, 1).isRest, isTrue);
      for (final k in kMotionKinds.keys) {
        final m = motionAt(MotionAnim(inn: k), 0.1, from: 0);
        expect(m.opacity, inInclusiveRange(0, 1), reason: k);
      }
    });

    test('a green key takes out green and keeps other colours', () {
      final m = const ChromaKey(
        color: 0xFF00FF00,
        strength: 0.6,
        soft: 0.2,
      ).matrix;
      expect(_alpha(m, 0, 255, 0), 0);
      expect(_alpha(m, 30, 220, 40), 0);
      expect(_alpha(m, 255, 0, 0), 255);
      expect(_alpha(m, 200, 180, 170), 255);
      expect(_alpha(m, 0, 0, 255), 255);
      final w = const ChromaKey(color: 0xFFFFFFFF, strength: 0.6).matrix;
      expect(_alpha(w, 255, 255, 255), 0);
      expect(_alpha(w, 10, 10, 10), 255);
    });

    test('mask shapes stay inside sensible bounds', () {
      for (final s in kMaskShapes.keys) {
        final p = LayerMask(shape: s).path(const Size(200, 100));
        expect(
          p.contains(const Offset(100, 50)) || s == 'line',
          isTrue,
          reason: s,
        );
      }
    });

    test('video edits with parts', () {
      const ve = VideoEdits(
        start: 0,
        end: 20,
        total: 20,
        parts: [(0, 5), (8, 20)],
        speed: 2,
      );
      expect(ve.split, isTrue);
      expect(ve.trimmed, isTrue);
      expect(ve.length, 17);
      expect(ve.playSeconds, 9);
      const plain = VideoEdits(start: 2, end: 10, total: 20);
      expect(plain.kept, [(2, 10)]);
      expect(plain.split, isFalse);
    });

    test('Android frame positions are microseconds', () {
      final was = debugFramesInMicros;
      addTearDown(() => debugFramesInMicros = was);
      debugFramesInMicros = true;
      expect(framePosition(1500), 1500000);
      expect(framePosition(-5), 0);
      expect(framePosition(99999999), 0x7FFFFFFF);
      debugFramesInMicros = false;
      expect(framePosition(1500), 1500);
    });
  });

  group('v1.29.0 widgets', () {
    testWidgets('layers show only in their time and masks wrap the clip', (
      t,
    ) async {
      final img = File('${Directory.systemTemp.path}/v1290_layer.png')
        ..writeAsBytesSync(_png);
      final clock = ValueNotifier<double>(0);
      addTearDown(clock.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 300,
              height: 500,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const MaskedBox(
                    mask: LayerMask(shape: 'circle', feather: 0.1),
                    child: ColoredBox(color: Colors.red),
                  ),
                  LayerStack(
                    clock: clock,
                    clipSeconds: 10,
                    layers: [
                      MediaLayer(
                        ref: img.path,
                        blend: 'multiply',
                        chroma: const ChromaKey(),
                        mask: const LayerMask(shape: 'star'),
                        anim: const MotionAnim(inn: 'fade'),
                        from: 2,
                        to: 5,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await t.pump();
      expect(find.byKey(const ValueKey('maskedBox')), findsNWidgets(1));
      expect(find.byKey(const ValueKey('layer0')), findsNothing);
      clock.value = 3;
      await t.pump();
      expect(find.byKey(const ValueKey('layer0')), findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget); // the blend
      expect(find.byType(ColorFiltered), findsOneWidget); // the key
      expect(find.byKey(const ValueKey('maskedBox')), findsNWidgets(2));
      final r = t.getRect(find.byKey(const ValueKey('layer0')));
      expect(r.width, closeTo(300 * 0.6, 0.5)); // default size
      clock.value = 6;
      await t.pump();
      expect(find.byKey(const ValueKey('layer0')), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('animate sheet', (t) async {
      MotionAnim? got;
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async =>
                    got = await showMotionSheet(context, null),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('motionSheet')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('animIn_fade')));
      await t.tap(find.byKey(const ValueKey('animOut_up')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('animDone')));
      await t.pumpAndSettle();
      expect(got!.inn, 'fade');
      expect(got!.out, 'up');
    });
  });

  group('v1.29.0 editor', () {
    late VideoPlayerPlatform old;
    late _FakePlayer fake;
    setUp(() {
      debugStickerClient = GiphyClient(key: '');
      old = VideoPlayerPlatform.instance;
      fake = _FakePlayer();
      VideoPlayerPlatform.instance = fake;
    });
    tearDown(() {
      VideoPlayerPlatform.instance = old;
      debugPickLayer = null;
    });

    testWidgets('split, overlay layers and mask come back from the editor', (
      t,
    ) async {
      EditorResult? result;
      final file = File('${Directory.systemTemp.path}/v1290_clip.mp4')
        ..writeAsBytesSync([0, 0, 0, 0]);
      final img = File('${Directory.systemTemp.path}/v1290_pick.png')
        ..writeAsBytesSync(_png);
      debugPickLayer = (video) async => (img, 1.0);
      await t.binding.setSurfaceSize(const Size(500, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<EditorResult>(
                      MaterialPageRoute(
                        builder: (_) => EditorScreen(
                          file: file,
                          video: true,
                          videoEdits: const VideoEdits(
                            start: 0,
                            end: 20,
                            total: 20,
                            parts: [(0, 5), (8, 20)],
                          ),
                        ),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pump(const Duration(milliseconds: 400));
      await _settle(
        t,
        () => find.byKey(const ValueKey('editTimeline')).evaluate().isNotEmpty,
      );

      // the saved parts come back: 17 of 20 seconds
      expect(find.text('0:00 / 0:17'), findsOneWidget);
      await _scrollTo(t, 'tool_split');
      await t.tap(find.byKey(const ValueKey('tool_split')));
      await t.pump();
      expect(find.byKey(const ValueKey('splitTools')), findsOneWidget);
      expect(find.byKey(const ValueKey('seg_2')), findsOneWidget);
      // put the middle part back, then take it out again
      await t.tap(find.byKey(const ValueKey('seg_1')));
      await t.pump();
      expect(find.text('0:00 / 0:20'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('seg_1')));
      await t.pump();
      expect(find.text('0:00 / 0:17'), findsOneWidget);
      // a photo on top: blend, key, mask
      await _scrollTo(t, 'tool_layer');
      await t.tap(find.byKey(const ValueKey('tool_layer')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('layerAddPhoto')));
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('layerChip0')), findsOneWidget);
      expect(find.byKey(const ValueKey('layerHandle')), findsOneWidget);
      expect(find.byKey(const ValueKey('layer0')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('blend_multiply')));
      await t.pump();
      await t.drag(
        find.byKey(const ValueKey('layerHandle')),
        const Offset(40, 0),
      );
      await t.pump();
      await t.tap(find.byKey(const ValueKey('layerTab1')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('key_green')));
      await t.pump();
      expect(find.byKey(const ValueKey('keyStrength')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('layerTab2')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('lm_circle')));
      await t.pump();
      expect(find.byKey(const ValueKey('lm_size')), findsOneWidget);

      // the clip's own mask
      await _scrollTo(t, 'tool_mask');
      await t.tap(find.byKey(const ValueKey('tool_mask')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('mask_heart')));
      await t.pump();
      expect(find.byKey(const ValueKey('maskDrag')), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('editorDone')));
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(milliseconds: 500));
      expect(result, isNotNull);
      final ve = result!.videoEdits!;
      expect(ve.parts, const [(0, 5), (8, 20)]);
      expect(ve.split, isTrue);
      final l = result!.layers.single;
      expect(l.ref, img.path);
      expect(l.blend, 'multiply');
      expect(l.chroma!.color, 0xFF00FF00);
      expect(l.mask!.shape, 'circle');
      expect(l.dx, greaterThan(0.5));
      expect(result!.mask!.shape, 'heart');
      expect(t.takeException(), isNull);
    });
  });
}
