import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:instantgram/core/theme.dart';
import 'package:instantgram/screens/post/editor_screen.dart';
import 'package:instantgram/widgets/edit_timeline.dart';

Future<void> _settle(WidgetTester t, bool Function() done) async {
  for (var i = 0; i < 30 && !done(); i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await t.pump(const Duration(milliseconds: 100));
  }
}

class _Calls {
  final List<double> seeks = [];
  final List<(double, double, bool)> ranges = [];
  final List<(int, double, double)> laneRanges = [];
  int seekStart = 0,
      seekEnd = 0,
      video = 0,
      mute = 0,
      addAudio = 0,
      audio = 0,
      addText = 0;
  final List<int> laneTaps = [];
}

void main() {
  group('the edit timeline', () {
    late ValueNotifier<double> pos;
    late _Calls c;

    setUp(() {
      pos = ValueNotifier(0);
      c = _Calls();
    });

    Future<void> pump(
      WidgetTester t, {
      double start = 0,
      double end = 20,
      bool videoSelected = false,
      String? audio,
      bool voice = false,
      List<EditLane> lanes = const [],
      int? maxSeconds,
    }) async {
      await t.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: EditTimeline(
                total: 20,
                start: start,
                end: end,
                position: pos,
                maxSeconds: maxSeconds,
                videoSelected: videoSelected,
                audioLabel: audio,
                voice: voice,
                lanes: lanes,
                height: 320,
                onSeekStart: () => c.seekStart++,
                onSeek: (v) {
                  c.seeks.add(v);
                  pos.value = v;
                },
                onSeekEnd: () => c.seekEnd++,
                onRange: (s, e, m) => c.ranges.add((s, e, m)),
                onVideoTap: () => c.video++,
                onMuteTap: () => c.mute++,
                onAddAudio: () => c.addAudio++,
                onAudioTap: () => c.audio++,
                onLaneTap: c.laneTaps.add,
                onLaneRange: (i, f, to) => c.laneRanges.add((i, f, to)),
                onAddText: () => c.addText++,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets(
      'the playhead stays in the middle and the empty tracks offer to add',
      (t) async {
        await pump(t);
        final tl = t.getRect(find.byKey(const ValueKey('editTimeline')));
        final ph = t.getRect(find.byKey(const ValueKey('playhead')));
        expect(ph.center.dx, closeTo(tl.center.dx, 1.5));
        expect(find.text('Add audio'), findsOneWidget);
        expect(find.text('Add text'), findsOneWidget);
        // at 0 s the clip starts right under the playhead
        final v = t.getRect(find.byKey(const ValueKey('videoTrack')));
        expect(v.left + 24, closeTo(ph.center.dx, 1.5));

        await t.tap(find.text('Add audio'));
        await t.tap(find.text('Add text'));
        await t.tap(find.byKey(const ValueKey('timelineMute')));
        expect([c.addAudio, c.addText, c.mute], [1, 1, 1]);
      },
    );

    testWidgets(
      'dragging to the left moves later into the clip, and the tracks follow',
      (t) async {
        await pump(t);
        final before = t.getRect(find.byKey(const ValueKey('videoTrack'))).left;
        await t.drag(
          find.byKey(const ValueKey('editTimeline')),
          const Offset(-150, 0),
        );
        await t.pump();
        expect(c.seekStart, 1);
        expect(c.seekEnd, 1);
        expect(c.seeks, isNotEmpty);
        expect(pos.value, greaterThan(1.5)); // ~48 points a second
        expect(pos.value, lessThan(3.5));
        final after = t.getRect(find.byKey(const ValueKey('videoTrack'))).left;
        expect(after, lessThan(before - 100));
        // never before the beginning
        await t.drag(
          find.byKey(const ValueKey('editTimeline')),
          const Offset(600, 0),
        );
        await t.pump();
        expect(pos.value, 0);
      },
    );

    testWidgets(
      'tap the clip to select it; its handles trim (and keep the longest allowed)',
      (t) async {
        await pump(t);
        // the handles are always there now
        expect(find.byKey(const ValueKey('trimEnd')), findsOneWidget);
        await t.tapAt(
          t.getRect(find.byKey(const ValueKey('videoTrack'))).centerLeft +
              const Offset(60, 0),
        );
        expect(c.video, 1);

        pos.value = 18; // the end of the clip is near the playhead
        await pump(t, videoSelected: true, maxSeconds: 15, start: 2, end: 17);
        await t.pump();
        expect(find.byKey(const ValueKey('trimEnd')), findsOneWidget);
        await t.drag(
          find.byKey(const ValueKey('trimEnd')),
          const Offset(-96, 0),
        );
        expect(c.ranges, isNotEmpty);
        final last = c.ranges.last;
        expect(last.$3, isFalse);
        expect(last.$2, lessThan(17));
        expect(last.$1, 2);
        // the end moved past 15 s of length: the start comes along
        c.ranges.clear();
        await t.drag(
          find.byKey(const ValueKey('trimEnd')),
          const Offset(96, 0),
        );
        final r = c.ranges.last;
        expect(r.$2 - r.$1, lessThanOrEqualTo(15.001));
      },
    );

    testWidgets('a song, a voiceover and texts each get a track', (t) async {
      await pump(
        t,
        audio: 'Summer song',
        voice: true,
        lanes: const [
          EditLane(label: 'Hello', from: 0, to: -1),
          EditLane(
            label: 'A caption',
            from: 1,
            to: 4,
            icon: Icons.closed_caption_rounded,
            selected: true,
          ),
        ],
      );
      expect(find.text('Add audio'), findsNothing);
      expect(find.text('Summer song'), findsOneWidget);
      expect(find.text('Voiceover'), findsOneWidget);
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('A caption'), findsOneWidget);
      expect(find.text('Add text'), findsOneWidget);
      // a long block: tap the part that is on screen
      await t.tapAt(
        t.getRect(find.byKey(const ValueKey('audioBlock'))).centerLeft +
            const Offset(30, 0),
      );
      expect(c.audio, 1);
      await t.tapAt(
        t.getRect(find.byKey(const ValueKey('textBlock0'))).centerLeft +
            const Offset(30, 0),
      );
      expect(c.laneTaps, [0]);
      // the selected caption: drag its end
      await t.drag(find.byKey(const ValueKey('laneEnd1')), const Offset(48, 0));
      expect(c.laneRanges, isNotEmpty);
      final l = c.laneRanges.last;
      expect(l.$1, 1);
      expect(l.$2, 1);
      expect(l.$3, greaterThan(4.5));
    });

    testWidgets('pinch to zoom spreads the seconds apart', (t) async {
      await pump(t, videoSelected: true);
      double gap() =>
          t.getRect(find.byKey(const ValueKey('trimEnd'))).center.dx -
          t.getRect(find.byKey(const ValueKey('trimStart'))).center.dx;
      final before = gap();
      final centre = t.getCenter(find.byKey(const ValueKey('editTimeline')));
      final a = await t.startGesture(centre - const Offset(40, 0));
      final b = await t.startGesture(centre + const Offset(40, 0));
      for (var i = 0; i < 10; i++) {
        await a.moveBy(const Offset(-8, 0));
        await b.moveBy(const Offset(8, 0));
        await t.pump();
      }
      await a.up();
      await b.up();
      await t.pump();
      expect(gap(), greaterThan(before * 1.5));
    });
  });

  group('the edit screen', () {
    File photo() {
      final src = File(
        '${Directory.systemTemp.createTempSync('ig').path}/p.jpg',
      );
      final im = img.Image(width: 80, height: 40);
      for (final p in im) {
        p.r = 200;
        p.g = 100;
        p.b = 50;
      }
      src.writeAsBytesSync(img.encodeJpg(im, quality: 95));
      return src;
    }

    Future<void> open(WidgetTester t) async {
      await t.binding.setSurfaceSize(const Size(500, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final f = photo();
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => EditorScreen(file: f, video: false),
                    ),
                  ),
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
        () => find.byKey(const ValueKey('tool_text')).evaluate().isNotEmpty,
      );
    }

    bool enabled(WidgetTester t, String key) {
      final ink = t.widget<InkWell>(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(InkWell),
        ),
      );
      return ink.onTap != null;
    }

    testWidgets(
      'top bar like the picture: close, title, round arrow; undo and redo',
      (t) async {
        await open(t);
        expect(find.byKey(const ValueKey('editorClose')), findsOneWidget);
        expect(find.byKey(const ValueKey('editorDone')), findsOneWidget);
        expect(find.text('Edit photo'), findsOneWidget);
        expect(find.byIcon(Icons.arrow_forward_rounded), findsOneWidget);
        expect(enabled(t, 'editorUndo'), isFalse);
        expect(enabled(t, 'editorRedo'), isFalse);
        // video-only tools are not offered for a photo
        expect(find.byKey(const ValueKey('tool_captions')), findsNothing);
        expect(find.byKey(const ValueKey('tool_voice')), findsNothing);
        expect(find.byKey(const ValueKey('editTimeline')), findsNothing);
      },
    );

    testWidgets('undo takes a change back, redo brings it again', (t) async {
      await open(t);
      // pick the second filter
      final filterTiles = find.descendant(
        of: find.byType(ListView).first,
        matching: find.byType(GestureDetector),
      );
      expect(filterTiles, findsWidgets);
      await t.tap(filterTiles.at(1));
      await t.pump();
      expect(enabled(t, 'editorUndo'), isTrue);

      await t.tap(find.byKey(const ValueKey('editorUndo')));
      await t.pump();
      expect(enabled(t, 'editorUndo'), isFalse);
      expect(enabled(t, 'editorRedo'), isTrue);

      await t.tap(find.byKey(const ValueKey('editorRedo')));
      await t.pump();
      expect(enabled(t, 'editorUndo'), isTrue);
      expect(enabled(t, 'editorRedo'), isFalse);
    });
  });
}
