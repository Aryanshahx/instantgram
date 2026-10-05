import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/screens/post/photo_editor_screen.dart';
import 'package:instantgram/widgets/like_button.dart';
import 'package:instantgram/widgets/post_media.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark,
  home: Scaffold(body: child),
);

Post _video({int w = 0, int h = 0}) => Post(
  id: 'p',
  authorId: 'u',
  authorUsername: 'n',
  authorPhotoUrl: '',
  type: 'video',
  caption: '',
  createdAt: DateTime(2026),
  videoRef: 'm:video/u/aaaaaaaaaaaaaaaa.mp4',
  videoWidth: w,
  videoHeight: h,
);

void main() {
  group('PostMedia shows real proportions with square corners', () {
    Future<Size> sizeFor(
      WidgetTester t,
      Post p, {
      double width = 300,
      double? maxHeight,
    }) async {
      await t.pumpWidget(
        _app(
          SingleChildScrollView(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: PostMedia(post: p, maxHeight: maxHeight),
              ),
            ),
          ),
        ),
      );
      return t.getSize(find.byType(PostMedia));
    }

    testWidgets('portrait 9:16 clip', (t) async {
      final s = await sizeFor(t, _video(w: 1080, h: 1920));
      expect(s.width, 300);
      expect(s.height, closeTo(300 * 16 / 9, 1));
      expect(find.byType(ClipRRect), findsNothing);
    });

    testWidgets('landscape 16:9 clip', (t) async {
      final s = await sizeFor(t, _video(w: 1920, h: 1080));
      expect(s.height, closeTo(300 * 9 / 16, 1));
    });

    testWidgets('square clip', (t) async {
      final s = await sizeFor(t, _video(w: 1000, h: 1000));
      expect(s.height, closeTo(300, 1));
    });

    testWidgets('unknown size defaults to 9:16', (t) async {
      final s = await sizeFor(t, _video());
      expect(s.height, closeTo(300 * 16 / 9, 1));
    });

    testWidgets('very tall media is capped and centred', (t) async {
      await t.pumpWidget(
        _app(
          SizedBox(
            width: 300,
            child: PostMedia(post: _video(w: 1080, h: 1920), maxHeight: 400),
          ),
        ),
      );
      final s = t.getSize(find.byType(PostMedia));
      expect(s.height, closeTo(400, 1));
      final inner = t.getSize(
        find.descendant(
          of: find.byType(PostMedia),
          matching: find.byType(LayoutBuilder),
        ),
      );
      expect(inner.height, closeTo(400, 1));
    });
  });

  testWidgets('heart button: outline, then a red heart when liked', (t) async {
    final c = LikeController('post1', 3);
    addTearDown(c.dispose);
    await t.pumpWidget(_app(Center(child: HeartButton(controller: c))));
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    c.liked = true;
    c.count = 4;
    c.notifyListeners();
    await t.pump(const Duration(milliseconds: 300));
    final icon = t.widget<Icon>(find.byIcon(Icons.favorite_rounded));
    expect(icon.color, kHeartColor);
    expect(find.text('4'), findsOneWidget);
  });

  group('Crop frame', () {
    test('free resize keeps the opposite corner fixed', () {
      final r = CropOverlay.resize(
        const Offset(0.2, 0.2),
        const Offset(0.8, 0.6),
        null,
        const Size(300, 400),
      );
      expect(r.left, closeTo(0.2, 1e-9));
      expect(r.top, closeTo(0.2, 1e-9));
      expect(r.right, closeTo(0.8, 1e-9));
      expect(r.bottom, closeTo(0.6, 1e-9));
    });

    test('locked 1:1 stays square in pixels and inside the photo', () {
      const box = Size(300, 400);
      for (final p in const [
        Offset(0.9, 0.9),
        Offset(0.5, 0.95),
        Offset(0.05, 0.1),
        Offset(0.7, 0.3),
      ]) {
        final r = CropOverlay.resize(const Offset(0.3, 0.5), p, 1, box);
        expect(r.width * box.width / (r.height * box.height), closeTo(1, 0.02));
        expect(r.left, greaterThanOrEqualTo(-1e-9));
        expect(r.top, greaterThanOrEqualTo(-1e-9));
        expect(r.right, lessThanOrEqualTo(1 + 1e-9));
        expect(r.bottom, lessThanOrEqualTo(1 + 1e-9));
      }
    });

    testWidgets('dragging a corner and moving the frame', (t) async {
      Rect rect = const Rect.fromLTWH(0.1, 0.1, 0.8, 0.8);
      await t.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, set) => Center(
              child: SizedBox(
                width: 300,
                height: 400,
                child: CropOverlay(
                  rect: rect,
                  photoAspect: 0.75,
                  onChanged: (r) => set(() => rect = r),
                ),
              ),
            ),
          ),
        ),
      );
      final box = t.getTopLeft(find.byType(CropOverlay));

      // drag the bottom-right corner (270, 360) to the left and up
      final g = await t.startGesture(box + const Offset(270, 360));
      await g.moveBy(const Offset(-60, -80));
      await g.up();
      await t.pump();
      expect(rect.right, closeTo(0.7, 0.03));
      expect(rect.bottom, closeTo(0.7, 0.03));
      expect(rect.left, closeTo(0.1, 1e-6));

      // drag from the middle: the frame moves, its size stays
      final before = rect;
      final m = await t.startGesture(box + const Offset(150, 150));
      await m.moveBy(const Offset(30, 40));
      await m.up();
      await t.pump();
      expect(rect.width, closeTo(before.width, 1e-6));
      expect(rect.left, greaterThan(before.left));
      expect(rect.top, greaterThan(before.top));
    });
  });

  testWidgets('photo editor opens, shows the tools and applies a rotation', (
    t,
  ) async {
    final dir = Directory.systemTemp.createTempSync('editor_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final src = File('${dir.path}/p.jpg');
    final im = img.Image(width: 80, height: 40);
    for (final p in im) {
      p.r = p.x < 40 ? 255 : 0;
      p.b = p.x < 40 ? 0 : 255;
    }
    src.writeAsBytesSync(img.encodeJpg(im, quality: 95));

    PhotoEditResult? result;
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<PhotoEditResult>(
                    MaterialPageRoute(
                      builder: (_) => PhotoEditorScreen(original: src),
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

    // the preview copy is built in the background (real time, not fake time)
    Future<void> waitFor(bool Function() done) async {
      for (var i = 0; i < 20 && !done(); i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    await waitFor(() => find.text('Crop').evaluate().isNotEmpty);
    expect(find.text('Crop'), findsOneWidget);
    expect(find.text('Filters'), findsOneWidget);
    expect(find.text('Adjust'), findsOneWidget);
    // opens on Filters, like Instagram
    expect(find.text('Mono'), findsOneWidget);
    expect(find.byType(CropOverlay), findsNothing);
    expect(find.byKey(const ValueKey('editorDone')), findsOneWidget);
    expect(find.byKey(const ValueKey('editorClose')), findsOneWidget);
    await t.tap(find.text('Adjust'));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Brightness'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(3));

    await t.tap(find.text('Crop'));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(CropOverlay), findsOneWidget);
    await t.tap(find.byIcon(Icons.rotate_right_rounded));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text('Done'));
    await t.pump(const Duration(milliseconds: 300));
    await waitFor(() => result != null);

    expect(result, isNotNull);
    expect(result!.edits.turns, 1);
    final out = img.decodeJpg(result!.file.readAsBytesSync())!;
    expect((out.width, out.height), (40, 80));
    expect(t.takeException(), isNull);
  });
}
