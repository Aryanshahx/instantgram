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
        () => find.byKey(const ValueKey('trimTimeline')).evaluate().isNotEmpty,
      );

      // the timeline is there from the start; there is no Trim tool any more
      expect(find.byKey(const ValueKey('trimTimeline')), findsOneWidget);
      expect(find.byKey(const ValueKey('tool_trim')), findsNothing);
      expect(find.byKey(const ValueKey('playhead')), findsOneWidget);
      expect(find.byKey(const ValueKey('lane0')), findsNothing);

      // a sticker brings its own lane
      await t.tap(find.byKey(const ValueKey('tool_stickers')));
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
      await t.ensureVisible(find.byKey(const ValueKey('emoji_🔥')));
      await t.tap(find.byKey(const ValueKey('emoji_🔥')));
      await t.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('laneBar0')), findsOneWidget);
      expect(find.byKey(const ValueKey('selectionBar')), findsOneWidget);

      // drag the end of the bar to the left: the sticker now goes away before the clip ends
      final box = t.getRect(find.byKey(const ValueKey('laneBar0')));
      await t.dragFrom(
        Offset(box.right - 4, box.center.dy),
        const Offset(-150, 0),
      );
      await t.pump(const Duration(milliseconds: 300));

      // dragging a handle of the strip does not flood the player with seeks
      final strip = t.getTopLeft(find.byKey(const ValueKey('trimTimeline')));
      await t.dragFrom(strip + const Offset(466, 30), const Offset(-150, 0));
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
}
