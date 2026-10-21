import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:instantgram/core/services/content_filter.dart';
import 'package:instantgram/core/services/media_service.dart';
import 'package:instantgram/core/services/vision_service.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/editor/edit_models.dart';
import 'package:instantgram/features/editor/media_editor_screen.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:instantgram/shared/widgets/styled_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

// v0.0.1: fast green screen (also for videos), turning texts / stickers,
// Instagram-like text boxes + more text styles.

List<int> _goodModel() {
  final b = List<int>.filled(kSegModelBytes, 0, growable: true);
  b.setAll(4, 'TFL3'.codeUnits);
  return b;
}

Future<void> _frames(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // --------------------------------------------------------- green screen
  group('green screen model (downloaded once, run by Play services)', () {
    late Directory dir;
    late List<MethodCall> calls;
    late bool faceReady;
    late bool prepareOk;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ig_seg');
      calls = [];
      faceReady = false;
      prepareOk = true;
      VisionService.instance.debugReset();
      VisionService.instance.debugModelDir = dir;
      messenger.setMockMethodCallHandler(VisionService.channel, (c) async {
        calls.add(c);
        switch (c.method) {
          case 'status':
            return (c.arguments as Map)['segment'] == false && faceReady;
          case 'install':
            faceReady = true;
            return true;
          case 'segPrepare':
            return prepareOk;
        }
        return null;
      });
    });

    tearDown(() async {
      messenger.setMockMethodCallHandler(VisionService.channel, null);
      VisionService.instance.debugReset();
      await dir.delete(recursive: true);
    });

    test('a whole model file is needed', () {
      expect(VisionService.goodModel(_goodModel()), isTrue);
      expect(VisionService.goodModel(_goodModel()..removeLast()), isFalse);
      expect(VisionService.goodModel(_goodModel()..[5] = 0), isFalse);
      expect(kSegModelPath, '/models/selfie_seg_v1.tflite');
    });

    test('downloads once, then loads it from the phone', () async {
      var fetched = 0;
      final v = VisionService.instance;
      v.debugFetchModel = () async {
        fetched++;
        return _goodModel();
      };
      expect(await v.isReady(segment: true), isFalse);
      await v.install(segment: true);
      final f = File('${dir.path}/selfie_seg_v1.tflite');
      expect(f.existsSync(), isTrue);
      expect(f.lengthSync(), kSegModelBytes);
      expect(File('${f.path}.part').existsSync(), isFalse);
      expect(fetched, 1);
      final prep = calls.lastWhere((c) => c.method == 'segPrepare');
      expect((prep.arguments as Map)['path'], f.path);
      expect(await v.isReady(segment: true), isTrue);
      // app opened again: the file is there, no new download
      v.debugReset();
      v.debugModelDir = dir;
      v.debugFetchModel = () async {
        fetched++;
        return _goodModel();
      };
      calls.clear();
      expect(await v.isReady(segment: true), isTrue);
      expect(calls.where((c) => c.method == 'segPrepare'), hasLength(1));
      await v.install(segment: true);
      expect(fetched, 1);
    });

    test('broken download -> message, nothing kept', () async {
      final v = VisionService.instance;
      v.debugFetchModel = () async => [1, 2, 3];
      await expectLater(
        v.install(segment: true),
        throwsA(
          isA<VisionException>().having(
            (e) => e.message,
            'message',
            "Couldn't download effects. Try again.",
          ),
        ),
      );
      expect(dir.listSync(), isEmpty);
      expect(v.progress.value, isNull);
      v.debugFetchModel = () async => throw const SocketException('x');
      await expectLater(
        v.install(segment: true),
        throwsA(
          isA<VisionException>().having(
            (e) => e.message,
            'message',
            'No internet. Connect and try again.',
          ),
        ),
      );
    });

    test('phone cannot run it -> clear message', () async {
      final v = VisionService.instance;
      prepareOk = false;
      v.debugFetchModel = () async => _goodModel();
      await expectLater(
        v.install(segment: true),
        throwsA(
          isA<VisionException>().having(
            (e) => e.message,
            'message',
            'Green screen needs Google Play services',
          ),
        ),
      );
      expect(await v.isReady(segment: true), isFalse);
    });
  });

  group('effects put into a filmed video', () {
    late List<MethodCall> calls;
    late Object? Function(MethodCall c) answer;

    setUp(() {
      calls = [];
      VisionService.instance.debugReset();
      messenger.setMockMethodCallHandler(VisionService.channel, (c) async {
        calls.add(c);
        return answer(c);
      });
    });
    tearDown(() {
      messenger.setMockMethodCallHandler(VisionService.channel, null);
      VisionService.instance.debugReset();
    });

    test('green screen with a photo behind', () async {
      answer = (_) => {'path': '/cache/fx_1.mp4', 'cancelled': false};
      final out = await VisionService.instance.fxVideo(
        '/v/a.mp4',
        mode: 'green',
        bg: '/p/beach.jpg',
      );
      expect(out, '/cache/fx_1.mp4');
      final a = calls.single.arguments as Map;
      expect(calls.single.method, 'fxVideo');
      expect(a, {'path': '/v/a.mp4', 'mode': 'green', 'bg': '/p/beach.jpg'});
      expect(VisionService.instance.progress.value, isNull);
    });

    test('cancelled -> null; failed -> message', () async {
      answer = (_) => {'cancelled': true};
      expect(
        await VisionService.instance.fxVideo('/v/a.mp4', mode: 'mono'),
        isNull,
      );
      answer = (_) => throw PlatformException(code: 'fx', message: 'codec');
      await expectLater(
        VisionService.instance.fxVideo('/v/a.mp4', mode: 'blur'),
        throwsA(isA<VisionException>()),
      );
      answer = (_) => {'path': '', 'cancelled': false};
      await expectLater(
        VisionService.instance.fxVideo('/v/a.mp4', mode: 'spot'),
        throwsA(isA<VisionException>()),
      );
    });
  });

  // --------------------------------------------------------- text look
  group('text look is saved with the post', () {
    test('all styles + turn go round trip', () {
      const o = VideoOverlay(
        kind: VideoOverlay.textKind,
        text: 'Hello\nworld',
        color: 0xFFFFD60A,
        background: true,
        bgStyle: TextBg.soft,
        align: 2,
        outline: true,
        glow: true,
        spacing: 0.12,
        rotation: -0.7854,
      );
      final m = o.toMap();
      expect(m['bs'], TextBg.soft);
      expect(m['a'], 2);
      expect(m['o'], true);
      expect(m['g'], true);
      expect(m['ls'], 0.12);
      expect(m['r'], -0.7854);
      final b = VideoOverlay.fromMap(m)!;
      expect(b.toMap(), m);
      expect(b.rotation, closeTo(-math.pi / 4, 1e-4));
      final s = TextSpec.ofOverlay(b);
      expect(s.bg, TextBg.soft);
      expect(s.align, 2);
      expect(s.textAlign, TextAlign.right);
      expect(s.outline && s.glow, isTrue);
      expect(s.spacing, 0.12);
    });

    test('old posts look the same; bad values are fixed', () {
      final old = VideoOverlay.fromMap({'k': 'text', 't': 'hi', 'bg': true})!;
      expect(old.bgStyle, 1);
      expect(old.align, 0);
      expect(old.rotation, 0);
      expect(old.outline || old.glow, isFalse);
      expect(TextSpec.ofOverlay(old).bg, TextBg.solid);
      // nothing extra saved for plain texts
      const plain = VideoOverlay(kind: VideoOverlay.textKind, text: 'x');
      expect(plain.toMap().keys.toSet(), {'k', 't', 'c', 'z', 'x', 'y'});
      final bad = VideoOverlay.fromMap({
        'k': 'text',
        't': 'x',
        'bs': 9,
        'a': 7,
        'ls': 5,
        'r': 1e9,
      })!;
      expect(bad.bgStyle, 1);
      expect(bad.align, 0);
      expect(bad.spacing, lessThanOrEqualTo(0.5));
      expect(bad.rotation.abs(), lessThanOrEqualTo(100));
      // box off -> no box, whatever the style
      const off = VideoOverlay(
        kind: VideoOverlay.textKind,
        text: 'x',
        bgStyle: 3,
      );
      expect(TextSpec.ofOverlay(off).bg, TextBg.none);
      expect(off.toMap().containsKey('bs'), isFalse);
    });

    test('photo text: same look as on screen', () {
      final l = TextLayer(
        text: 'Hey',
        color: Colors.black,
        background: true,
        bgStyle: TextBg.inverse,
        align: 1,
        glow: true,
        spacing: 0.2,
        rotation: 1,
      );
      final s = l.spec;
      expect(s.bg, TextBg.inverse);
      expect(s.align, 1);
      expect(s.glow, isTrue);
      expect(s.spacing, 0.2);
      l.background = false;
      expect(l.spec.bg, TextBg.none);
    });

    testWidgets('box around each line; outline = 2 layers', (t) async {
      final plain = StyledTextLayout(
        const TextSpec(text: 'Hi there'),
        fontSize: 20,
        maxWidth: 300,
      );
      final boxed = StyledTextLayout(
        const TextSpec(text: 'Hi there', bg: TextBg.solid),
        fontSize: 20,
        maxWidth: 300,
      );
      final twoLines = StyledTextLayout(
        const TextSpec(text: 'Hi there\nfriend', bg: TextBg.solid),
        fontSize: 20,
        maxWidth: 300,
      );
      expect(boxed.size.width, closeTo(plain.size.width + 2 * 20 * 0.42, 1));
      expect(twoLines.size.height, greaterThan(boxed.size.height * 1.6));
      plain.dispose();
      boxed.dispose();
      twoLines.dispose();

      await t.pumpWidget(
        const MaterialApp(
          home: Center(
            child: StyledText(
              spec: TextSpec(text: 'Neon', outline: true, glow: true),
              fontSize: 30,
              maxWidth: 300,
            ),
          ),
        ),
      );
      expect(find.text('Neon'), findsNWidgets(2));
      await t.pumpWidget(
        const MaterialApp(
          home: Center(
            child: StyledText(
              spec: TextSpec(text: 'Box', bg: TextBg.soft),
              fontSize: 30,
              maxWidth: 300,
            ),
          ),
        ),
      );
      expect(find.text('Box'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(StyledText),
          matching: find.byType(CustomPaint),
        ),
        findsWidgets,
      );
    });
  });

  // --------------------------------------------------------- editor
  testWidgets('editor: styled text, then turn it with the handle', (t) async {
    NetImage.disableCache = true;
    SharedPreferences.setMockInitialValues({});
    ContentFilter.instance.debugSet(me: 'me');
    final dir = (await t.runAsync(
      () => Directory.systemTemp.createTemp('ig_editor'),
    ))!;
    final f = File('${dir.path}/p.png');
    await t.runAsync(
      () => f.writeAsBytes(img.encodePng(img.Image(width: 40, height: 60))),
    );
    await t.binding.setSurfaceSize(const Size(400, 800));
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: MediaEditorScreen(
          media: [PickedMedia(f, isVideo: false)],
          mode: ComposeMode.photo,
          onDone: (_) {},
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump();
      if (find.byType(InteractiveViewer).evaluate().isNotEmpty) break;
    }
    // Text tool -> Add text
    await t.tap(find.byIcon(Icons.text_fields).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Add text'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('text-preview')), findsOneWidget);
    await t.enterText(find.byType(TextField).first, 'Hello');
    await t.pump();

    StyledText preview() => t.widget<StyledText>(
      find.descendant(
        of: find.byKey(const ValueKey('text-preview')),
        matching: find.byType(StyledText),
      ),
    );
    expect(preview().spec.text, 'Hello');
    expect(preview().spec.bg, TextBg.none);
    // box: solid -> your colour -> see-through
    await t.tap(find.byKey(const ValueKey('text-bg')));
    await t.pump();
    expect(preview().spec.bg, TextBg.solid);
    await t.tap(find.byKey(const ValueKey('text-bg')));
    await t.pump();
    expect(preview().spec.bg, TextBg.inverse);
    await t.tap(find.byKey(const ValueKey('text-align')));
    await t.pump();
    expect(preview().spec.align, isNot(0));
    await t.tap(find.byKey(const ValueKey('text-outline')));
    await t.tap(find.byKey(const ValueKey('text-glow')));
    await t.pump();
    expect(preview().spec.outline, isTrue);
    expect(preview().spec.glow, isTrue);
    // any colour
    expect(find.byKey(const ValueKey('text-hue')), findsNothing);
    await t.ensureVisible(find.byKey(const ValueKey('text-color-custom')));
    await t.tap(find.byKey(const ValueKey('text-color-custom')));
    await t.pump();
    expect(find.byKey(const ValueKey('text-hue')), findsOneWidget);
    final before = preview().spec.color;
    await t.tap(find.byKey(const ValueKey('text-hue')));
    await t.pump();
    expect(preview().spec.color, isNot(before));
    // letter spacing
    await t.ensureVisible(find.byKey(const ValueKey('text-spacing')));
    await t.drag(
      find.byKey(const ValueKey('text-spacing')),
      const Offset(120, 0),
    );
    await t.pump();
    expect(preview().spec.spacing, greaterThan(0));
    final want = preview().spec;
    await t.ensureVisible(find.text('Done'));
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();

    // on the photo, same look
    final onPhoto = find.byWidgetPredicate(
      (w) => w is StyledText && w.spec.text == 'Hello',
    );
    expect(onPhoto, findsOneWidget);
    final got = t.widget<StyledText>(onPhoto).spec;
    expect(got.bg, want.bg);
    expect(got.align, want.align);
    expect(got.outline && got.glow, isTrue);
    expect(got.spacing, want.spacing);
    expect(got.color, want.color);

    // touch it (no tap = no edit sheet) -> the turn handle shows
    final g0 = await t.startGesture(t.getCenter(onPhoto));
    await t.pump();
    for (var i = 0; i < 4; i++) {
      await g0.moveBy(const Offset(0, 10));
      await t.pump();
    }
    await g0.up();
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('text-preview')), findsNothing);
    final handle = find.byKey(const ValueKey('text-resize'));
    expect(handle, findsOneWidget);

    double angle() {
      final tr = t.widget<Transform>(
        find.ancestor(of: onPhoto, matching: find.byType(Transform)).first,
      );
      return math.atan2(tr.transform.entry(1, 0), tr.transform.entry(0, 0));
    }

    expect(angle(), 0);
    // drag the handle a quarter way round the middle of the text
    final c = t.getCenter(onPhoto);
    final h = t.getCenter(handle);
    final r = (h - c).distance;
    final a0 = (h - c).direction;
    final g = await t.startGesture(h);
    for (var i = 1; i <= 12; i++) {
      final a = a0 + (math.pi / 4) * i / 12;
      await g.moveTo(c + Offset(math.cos(a), math.sin(a)) * r);
      await t.pump();
    }
    await g.up();
    await t.pump();
    expect(angle(), closeTo(math.pi / 4, 0.12));
    expect(handle, findsOneWidget, reason: 'the drag was not cut off');

    // near a straight angle it snaps
    final g2 = await t.startGesture(t.getCenter(handle));
    final c2 = t.getCenter(onPhoto);
    final h2 = t.getCenter(handle);
    final a2 = (h2 - c2).direction;
    final r2 = (h2 - c2).distance;
    for (var i = 1; i <= 10; i++) {
      final a = a2 + (math.pi / 4 + 0.04) * i / 10;
      await g2.moveTo(c2 + Offset(math.cos(a), math.sin(a)) * r2);
      await t.pump();
    }
    await g2.up();
    await t.pump();
    expect(angle(), closeTo(math.pi / 2, 1e-9));

    await t.binding.setSurfaceSize(null);
    await t.pumpWidget(const SizedBox());
    await _frames(t, 20);
    await t.runAsync(() => dir.delete(recursive: true));
  });
}
