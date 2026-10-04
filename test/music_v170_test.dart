import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/share.dart';
import 'package:instantgram/models/music.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/widgets/inline_video.dart';
import 'package:instantgram/widgets/reel_touch.dart';

Post _post(String type, {String musicId = ''}) => Post(
  id: 'p',
  authorId: 'u',
  authorUsername: 'user',
  authorPhotoUrl: '',
  type: type,
  caption: 'hello caption',
  createdAt: DateTime(2026, 1, 1),
  imageRef: 'https://cdn.test/photo.jpg',
  videoRef: 'https://cdn.test/clip.mp4',
  musicId: musicId,
);

void main() {
  group('music library', () {
    test('ids are unique and every id has a name', () {
      final ids = kMusicLibrary.map((t) => t.id).toSet();
      expect(ids.length, kMusicLibrary.length);
      expect(kMusicLibrary.length, greaterThanOrEqualTo(6));
      for (final t in kMusicLibrary) {
        expect(t.title.trim(), isNotEmpty);
        expect(t.seconds, greaterThanOrEqualTo(10));
      }
    });

    test('every track has an mp3 file with a valid header', () {
      for (final t in kMusicLibrary) {
        final f = File(t.asset);
        expect(f.existsSync(), isTrue, reason: t.asset);
        final head = f.openSync().readSync(3);
        final id3 = head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33;
        final sync = head[0] == 0xFF && (head[1] & 0xE0) == 0xE0;
        expect(id3 || sync, isTrue, reason: '${t.asset} is not an mp3');
        expect(f.lengthSync(), greaterThan(50000), reason: t.asset);
      }
    });

    test('pubspec lists the music folder', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('assets/music/'),
      );
    });

    test('musicById finds tracks and tolerates unknown ids', () {
      expect(musicById(kMusicLibrary.first.id)?.id, kMusicLibrary.first.id);
      expect(musicById('no_such_track'), isNull);
    });
  });

  group('Post types', () {
    test('photo clips count as clips, plain photos do not', () {
      expect(_post('video').isClip, isTrue);
      expect(_post('photoclip').isClip, isTrue);
      expect(_post('photoclip').isVideo, isFalse);
      expect(_post('image').isClip, isFalse);
    });

    test('hasMusic follows musicId', () {
      expect(_post('image').hasMusic, isFalse);
      expect(_post('image', musicId: 'pulse').hasMusic, isTrue);
    });
  });

  group('share link', () {
    test('video shares the video link, photos share the photo link', () {
      expect(shareLinkFor(_post('video')), 'https://cdn.test/clip.mp4');
      expect(shareLinkFor(_post('image')), 'https://cdn.test/photo.jpg');
      expect(shareLinkFor(_post('photoclip')), 'https://cdn.test/photo.jpg');
    });
  });

  group('pickInlineActive', () {
    test('nothing is picked when nothing is visible', () {
      expect(
        pickInlineActive(
          const [InlineSpot('a', 900, 300)],
          viewTop: 0,
          viewBottom: 800,
        ),
        isNull,
      );
    });

    test('a barely visible clip does not play, a mostly visible one does', () {
      const view = (top: 0.0, bottom: 800.0);
      expect(
        pickInlineActive(
          const [InlineSpot('a', 700, 400)],
          viewTop: view.top,
          viewBottom: view.bottom,
        ),
        isNull,
      );
      expect(
        pickInlineActive(
          const [InlineSpot('a', 300, 400)],
          viewTop: view.top,
          viewBottom: view.bottom,
        ),
        'a',
      );
    });

    test('the clip closest to the middle wins', () {
      expect(
        pickInlineActive(
          const [InlineSpot('a', 20, 300), InlineSpot('b', 330, 300)],
          viewTop: 0,
          viewBottom: 800,
        ),
        'b',
      );
    });

    test('a very tall clip plays when it fills much of the screen', () {
      expect(
        pickInlineActive(
          const [InlineSpot('tall', -600, 1500)],
          viewTop: 0,
          viewBottom: 800,
        ),
        'tall',
      );
    });
  });

  group('ReelTouch volume', () {
    setUp(() {
      ReelAudio.muted.value = false;
      ReelAudio.volume.value = 0.5;
    });

    testWidgets('hold and slide up raises the volume, down lowers it', (
      tester,
    ) async {
      var taps = 0;
      final speeds = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 800,
            child: ReelTouch(
              onTap: () => taps++,
              onSpeed: speeds.add,
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );
      final g = await tester.startGesture(const Offset(200, 400));
      await tester.pump(const Duration(milliseconds: 600));
      expect(speeds, [true]); // holding still = 2x
      await g.moveBy(const Offset(0, -80));
      await tester.pump(const Duration(milliseconds: 50));
      await g.moveBy(const Offset(0, -80));
      await tester.pump(const Duration(milliseconds: 50));
      expect(speeds, [true, false]); // sliding cancels 2x
      final up = ReelAudio.volume.value;
      expect(up, greaterThan(0.5));
      await g.moveBy(const Offset(0, 300));
      await tester.pump(const Duration(milliseconds: 50));
      expect(ReelAudio.volume.value, lessThan(up));
      await g.up();
      await tester.pump(const Duration(seconds: 1));
      expect(taps, 0);
    });

    testWidgets('sliding to the top is 100% and a short hold keeps 2x only', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 800,
            child: ReelTouch(
              onTap: () {},
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );
      final g = await tester.startGesture(const Offset(200, 550));
      await tester.pump(const Duration(milliseconds: 600));
      await g.moveBy(const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 50));
      expect(ReelAudio.volume.value, 1.0);
      await g.up();
      await tester.pump(const Duration(seconds: 1));

      ReelAudio.volume.value = 0.3;
      final h = await tester.startGesture(const Offset(200, 400));
      await tester.pump(const Duration(milliseconds: 600));
      await h.up();
      await tester.pump(const Duration(seconds: 1));
      expect(ReelAudio.volume.value, 0.3);
    });

    testWidgets('inside the Clips page list: hold + slide is volume, a quick '
        'swipe still changes clip', (tester) async {
      final pages = PageController();
      addTearDown(pages.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: PageView(
            controller: pages,
            scrollDirection: Axis.vertical,
            children: [
              for (var i = 0; i < 3; i++)
                ReelTouch(
                  onTap: () {},
                  child: const ColoredBox(color: Colors.black),
                ),
            ],
          ),
        ),
      );
      // hold for about a third of a second, then slide up
      final g = await tester.startGesture(const Offset(400, 400));
      await tester.pump(const Duration(milliseconds: 300));
      await g.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 50));
      await g.moveBy(const Offset(0, -120));
      await tester.pump(const Duration(milliseconds: 50));
      await g.up();
      await tester.pumpAndSettle();
      expect(ReelAudio.volume.value, greaterThan(0.5));
      expect(pages.page, 0); // the page did not move

      // a quick swipe (no hold) moves to the next clip
      await tester.fling(find.byType(PageView), const Offset(0, -300), 1500);
      await tester.pumpAndSettle();
      expect(pages.page, 1);
    });
  });
}
