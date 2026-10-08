// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/screens/post/editor_screen.dart';
import 'package:instantgram/services/giphy.dart';
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

void main() {
  late VideoPlayerPlatform old;
  late _FakePlayer fake;
  setUp(() {
    debugStickerClient = GiphyClient(key: '');
    old = VideoPlayerPlatform.instance;
    fake = _FakePlayer();
    VideoPlayerPlatform.instance = fake;
  });
  tearDown(() => VideoPlayerPlatform.instance = old);

  testWidgets(
    'a video always shows its timeline; texts and stickers get lanes with times',
    (t) async {
      EditorResult? result;
      final file = File('${Directory.systemTemp.path}/v1160_clip.mp4')
        ..writeAsBytesSync([0, 0, 0, 0]);
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
                        builder: (_) => EditorScreen(file: file, video: true),
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

      // the timeline is there from the start, with the playhead in the middle
      expect(find.byKey(const ValueKey('editTimeline')), findsOneWidget);
      expect(find.byKey(const ValueKey('tool_trim')), findsNothing);
      expect(find.byKey(const ValueKey('playhead')), findsOneWidget);
      expect(find.byKey(const ValueKey('textLane0')), findsNothing);
      expect(find.text('Add audio'), findsOneWidget);
      expect(find.text('Add text'), findsOneWidget);
      expect(
        find.text('Tap on a track to trim. Pinch to zoom.'),
        findsOneWidget,
      );
      expect(find.text('0:00 / 0:20'), findsOneWidget);
      for (final k in [
        'tool_audio',
        'tool_text',
        'tool_voice',
        'tool_captions',
        'tool_stickers',
        'tool_filters',
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      expect(find.text('New'), findsNWidgets(2)); // Voice and Captions

      // a sticker brings its own track, selected
      await t.tap(find.byKey(const ValueKey('tool_stickers')));
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
      await t.ensureVisible(find.byKey(const ValueKey('emoji_🔥')));
      await t.tap(find.byKey(const ValueKey('emoji_🔥')));
      await t.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('textLane0')), findsOneWidget);
      expect(find.byKey(const ValueKey('selectionBar')), findsOneWidget);

      // move to near the end of the clip: drag the time marks to the left
      final tl = t.getRect(find.byKey(const ValueKey('editTimeline')));
      await t.dragFrom(
        tl.topCenter + const Offset(0, 12),
        const Offset(-800, 0),
      );
      await t.pump(const Duration(milliseconds: 300));

      // the sticker's end is now in view: drag it to the left (it goes before the end)
      expect(find.byKey(const ValueKey('laneEnd0')), findsOneWidget);
      await t.drag(
        find.byKey(const ValueKey('laneEnd0')),
        const Offset(-150, 0),
      );
      await t.pump(const Duration(milliseconds: 300));

      // select the clip and pull its end handle: a trim, without flooding the player
      final v = t.getRect(find.byKey(const ValueKey('videoTrack')));
      await t.tapAt(Offset(tl.left + 120, v.center.dy));
      await t.pump();
      expect(find.byKey(const ValueKey('trimEnd')), findsOneWidget);
      fake.seeks.clear();
      await t.drag(
        find.byKey(const ValueKey('trimEnd')),
        const Offset(-150, 0),
      );
      await t.pump(const Duration(milliseconds: 300));
      expect(fake.seeks.length, lessThan(40));

      await t.tap(find.byKey(const ValueKey('editorDone')));
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(milliseconds: 500));
      expect(result, isNotNull);
      expect(result!.overlays, hasLength(1));
      final o = result!.overlays.single;
      expect(o.from, 0);
      expect(o.to, greaterThan(0));
      expect(o.to, lessThan(20));
      expect(result!.videoEdits, isNotNull, reason: 'the end handle was moved');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('captions: a timed line low on the clip; undo and redo', (
    t,
  ) async {
    EditorResult? result;
    final file = File('${Directory.systemTemp.path}/v1200_clip.mp4')
      ..writeAsBytesSync([0, 0, 0, 0]);
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
                      builder: (_) => EditorScreen(file: file, video: true),
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

    bool on(String key) =>
        t
            .widget<InkWell>(
              find.descendant(
                of: find.byKey(ValueKey(key)),
                matching: find.byType(InkWell),
              ),
            )
            .onTap !=
        null;
    expect(on('editorUndo'), isFalse);

    await t.tap(find.byKey(const ValueKey('tool_captions')));
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 1));
    await t.enterText(find.byKey(const ValueKey('storyTextInput')), 'Hello there');
    await t.tap(find.byKey(const ValueKey('storyTextDone')));
    await t.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('textLane0')), findsOneWidget);
    expect(on('editorUndo'), isTrue);

    // undo removes the caption, redo brings it back
    await t.tap(find.byKey(const ValueKey('editorUndo')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('textLane0')), findsNothing);
    expect(on('editorRedo'), isTrue);
    await t.tap(find.byKey(const ValueKey('editorRedo')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('textLane0')), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('editorDone')));
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    final o = result!.overlays.single;
    expect(o.text, 'Hello there');
    expect(o.pill, isTrue);
    expect(o.dy, greaterThan(0.75));
    expect(o.from, closeTo(0, 0.5));
    expect(o.to, closeTo(o.from + 3, 0.01));
    expect(t.takeException(), isNull);
  });
}
