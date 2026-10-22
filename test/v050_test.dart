import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/constants/countries.dart';
import 'package:instantgram/core/services/media_service.dart';
import 'package:instantgram/core/services/music_player.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/auth/presentation/choose_language_screen.dart';
import 'package:instantgram/features/editor/photo_render.dart';
import 'package:instantgram/features/insights/post_insights.dart';
import 'package:instantgram/features/insights/post_insights_screen.dart';
import 'package:instantgram/features/post/data/post_repository.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/widgets/media_view.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';

Widget _app(Widget child) => MaterialApp(theme: AppTheme.dark, home: child);

/// 200 x 100 photo: left half red, right half blue.
Future<ui.Image> _redBlue() async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(
    const Rect.fromLTWH(0, 0, 100, 100),
    Paint()..color = const Color(0xFFFF0000),
  );
  c.drawRect(
    const Rect.fromLTWH(100, 0, 100, 100),
    Paint()..color = const Color(0xFF0000FF),
  );
  final pic = rec.endRecording();
  final img = await pic.toImage(200, 100);
  pic.dispose();
  return img;
}

Future<Color> _px(ui.Image img, int x, int y) async {
  final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final i = (y * img.width + x) * 4;
  return Color.fromARGB(
    data.getUint8(i + 3),
    data.getUint8(i),
    data.getUint8(i + 1),
    data.getUint8(i + 2),
  );
}

bool _isRed(Color c) => c.r > 0.8 && c.b < 0.2 && c.g < 0.2;
bool _isBlue(Color c) => c.b > 0.8 && c.r < 0.2 && c.g < 0.2;

Post _post(Map<String, dynamic> m) => Post.fromMap('p1', {
  'authorId': 'a1',
  'authorUsername': 'riya',
  'type': 'photo',
  'mediaUrl': 'https://x/1.jpg',
  'createdAt': DateTime(2026, 10, 1),
  ...m,
});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MusicPlayer.disabled = true;
    kDisableVideoPlayback = true;
    NetImage.disableCache = true;
  });

  // ------------------------------------------------------------ editor export
  testWidgets('photo export: shape, rotate, flip, zoom, filter', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final src = await _redBlue();
      Future<ui.Image> render({
        int turns = 0,
        bool flip = false,
        Matrix4? zoom,
        List<double>? color,
      }) {
        final layout = PhotoLayout.compute(
          natural: const Size(200, 100),
          turns: turns,
          aspect: turns.isOdd ? 0.5 : 2,
          box: const Size(100, 100),
        );
        return renderPhoto(
          src,
          PhotoRenderSpec(
            layout: layout,
            transform: zoom ?? layout.centered(),
            turns: turns,
            flip: flip,
            colorMatrix: color,
          ),
          outWidth: 20,
        );
      }

      // plain: 20 x 10, red left, blue right
      var img = await render();
      expect(img.width, 20);
      expect(img.height, 10);
      expect(_isRed(await _px(img, 2, 5)), isTrue);
      expect(_isBlue(await _px(img, 17, 5)), isTrue);

      // flipped
      img = await render(flip: true);
      expect(_isBlue(await _px(img, 2, 5)), isTrue);
      expect(_isRed(await _px(img, 17, 5)), isTrue);

      // rotated right: portrait, red on top
      img = await render(turns: 1);
      expect(img.width, 20);
      expect(img.height, 40);
      expect(_isRed(await _px(img, 10, 4)), isTrue);
      expect(_isBlue(await _px(img, 10, 35)), isTrue);

      // zoom 2x on the left -> all red; moved right -> all blue
      img = await render(zoom: Matrix4.diagonal3Values(2, 2, 1));
      expect(_isRed(await _px(img, 2, 5)), isTrue);
      expect(_isRed(await _px(img, 17, 5)), isTrue);
      img = await render(
        zoom: Matrix4.translationValues(-100, 0, 0)
          ..multiply(Matrix4.diagonal3Values(2, 2, 1)),
      );
      expect(_isBlue(await _px(img, 2, 5)), isTrue);
      expect(_isBlue(await _px(img, 17, 5)), isTrue);

      // black and white filter
      const gray = <double>[
        0.33, 0.33, 0.33, 0, 0, //
        0.33, 0.33, 0.33, 0, 0,
        0.33, 0.33, 0.33, 0, 0,
        0, 0, 0, 1, 0,
      ];
      img = await render(color: gray);
      final c = await _px(img, 2, 5);
      expect((c.r - c.g).abs() < 0.02 && (c.g - c.b).abs() < 0.02, isTrue);
      src.dispose();
    });
  });

  test('layout keeps the real photo shape', () {
    final l = PhotoLayout.compute(
      natural: const Size(1080, 1920),
      turns: 0,
      aspect: 1080 / 1920,
      box: const Size(400, 400),
    );
    expect(l.frame.height, 400);
    expect(l.frame.width, closeTo(225, 0.01));
    expect(l.photo, l.frame);
  });

  // ------------------------------------------------------------ posts
  test('mixed post: photos + videos, music, no 10 limit', () {
    final media = [
      for (var i = 0; i < 25; i++)
        {
          'type': i.isOdd ? 'video' : 'photo',
          'url': 'https://x/$i',
          'key': 'k$i',
          'aspectRatio': i.isOdd ? 9 / 16 : 4 / 5,
          if (i.isOdd) 'thumbUrl': 'https://x/t$i.jpg',
        },
    ];
    final p = _post({
      'media': media,
      'audioUrl': 'https://x/song.mp3',
      'audioName': 'My song',
      'uniqueViews': 7,
      'viewsCount': 999, // old wrong number is ignored
      'savesCount': 2,
    });
    expect(p.items.length, 25);
    expect(PostRepository.maxItems >= 200, isTrue);
    expect(p.isMulti, isTrue);
    expect(p.hasVideo, isTrue);
    expect(p.startsWithVideo, isFalse);
    expect(p.hasMusic, isTrue);
    expect(p.viewsCount, 7);
    expect(p.savesCount, 2);
    expect(p.items[1].coverUrl, 'https://x/t1.jpg');
  });

  test('old one-video clip still works', () {
    final p = _post({
      'type': 'clip',
      'mediaUrl': 'https://x/v.mp4',
      'thumbUrl': 'https://x/v.jpg',
      'aspectRatio': 9 / 16,
    });
    expect(p.items.length, 1);
    expect(p.items.first.isVideo, isTrue);
    expect(p.coverUrl, 'https://x/v.jpg');
    expect(p.viewsCount, 0);
  });

  test('page dots window stays around the current page', () {
    expect(PageDots.window(5, 2), (0, 4));
    final (a, b) = PageDots.window(200, 100);
    expect(b - a + 1, PageDots.maxDots);
    expect(a <= 100 && 100 <= b, isTrue);
    expect(PageDots.window(200, 199).$2, 199);
  });

  test('music name from file name', () {
    expect(audioTitle('/cache/My_Song.mp3'), 'My Song');
    expect(audioTitle('.mp3'), '.mp3');
    expect(audioTitle(''), 'Music');
  });

  test('card shape: real size, limited to 9:16 .. 1.91:1', () {
    expect(cardAspectFor(_post({'aspectRatio': 0.3})), closeTo(9 / 16, 0.001));
    expect(cardAspectFor(_post({'aspectRatio': 1.0})), 1.0);
    expect(cardAspectFor(_post({'aspectRatio': 3.0})), closeTo(1.91, 0.001));
  });

  testWidgets('Discover media: mixed post swipes, counts, sees, no crash', (
    tester,
  ) async {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    var seen = 0;
    final p = _post({
      'aspectRatio': 0.2, // very tall -> limited to 9:16
      'audioUrl': 'https://x/a.mp3',
      'audioName': 'Song',
      'media': [
        {'type': 'photo', 'url': 'https://x/1.jpg', 'aspectRatio': 0.2},
        {'type': 'video', 'url': 'https://x/2.mp4', 'aspectRatio': 1.7},
        {'type': 'photo', 'url': 'https://x/3.jpg', 'aspectRatio': 1.0},
      ],
    });
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: ListView(
            children: [PostMedia(post: p, onSeen: () => seen++)],
          ),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('1/3'), findsOneWidget);
    // v0.0.1: the song name is under the name now (post header), not on the
    // picture
    expect(find.text('Song'), findsNothing);
    expect(seen, 1);
    final box = tester.getSize(find.byType(PageView));
    expect(box.width / box.height, closeTo(9 / 16, 0.01));
    await tester.flingFrom(const Offset(400, 300), const Offset(-300, 0), 1000);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('2/3'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  // ------------------------------------------------------------ countries
  test('countries: names, flags, search', () {
    expect(kCountries.length, greaterThan(240));
    expect(kCountries.map((e) => e.$1).toSet().length, kCountries.length);
    expect(countryName('IN'), 'India');
    expect(countryName('in'), 'India');
    expect(flagOf('IN'), '🇮🇳');
    expect(flagOf('x'), '🏳');
    expect(searchCountries('ind').map((e) => e.$1), contains('IN'));
    expect(searchCountries('us').map((e) => e.$1), contains('US'));
  });

  // ------------------------------------------------------------ analytics
  test('analytics totals', () {
    final p = _post({
      'uniqueViews': 4,
      'likesCount': 2,
      'commentsCount': 1,
      'sharesCount': 1,
      'createdAt': DateTime(2026, 10, 13, 8),
    });
    final docs = [
      {
        'follower': true,
        'country': 'IN',
        'ageGroup': '18-24',
        'language': 'hi',
        'source': 'feed',
        'count': 3,
        'createdAt': DateTime(2026, 10, 13, 9, 10),
      },
      {
        'follower': false,
        'country': 'IN',
        'ageGroup': '25-34',
        'language': 'en',
        'source': 'clips',
        'count': 1,
        'watchMs': 4000,
        'completed': true,
        'createdAt': DateTime(2026, 10, 13, 9, 50),
      },
      {
        'follower': false,
        'country': 'US',
        'ageGroup': '18-24',
        'language': 'en',
        'source': 'weird',
        'count': 1,
        'watchMs': 2000,
        'createdAt': DateTime(2026, 10, 13, 11),
      },
    ];
    final d = PostInsights.from(p, docs, now: DateTime(2026, 10, 13, 12));
    expect(d.reach, 4); // counter is bigger than docs (old views)
    expect(d.views, 4); // v0.0.1: one view per person (rewatches don't count)
    expect(d.detailed, 3);
    expect(d.followerViews, 1);
    expect(d.nonFollowerViews, 2);
    expect(d.countries.first, ('IN', 2));
    expect(d.ages.first, ('18-24', 2));
    expect(d.languages.first, ('en', 2));
    expect(d.sources.map((e) => e.$1), contains(ViewSource.other));
    expect(d.interactions, 4);
    expect(d.engagementRate, 1.0);
    expect(d.avgWatchMs, 3000);
    // v0.20: the view without watch data is not counted
    expect(d.completionRate, 0.5);
    expect(d.watchDocs, 2);
    expect(d.hourly, isTrue);
    expect(d.timeline.length, 5); // 8:00 .. 12:00
    expect(d.timeline[1].$2, 2); // two views in the 9:00 hour
    expect(d.timeline[3].$2, 1);
  });

  testWidgets('analytics screen shows overview and audience', (tester) async {
    final p = _post({'uniqueViews': 2, 'likesCount': 1});
    await tester.pumpWidget(
      _app(
        PostInsightsScreen(
          post: p,
          loader: () async => [
            {
              'follower': true,
              'country': 'IN',
              'ageGroup': '18-24',
              'count': 2,
            },
            {
              'follower': false,
              'country': 'IN',
              'ageGroup': '18-24',
              'count': 1,
            },
          ],
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Post analytics'), findsOneWidget);
    expect(find.text('Views'), findsOneWidget);
    expect(find.text('2'), findsWidgets); // v0.0.1: 2 people = 2 views
    expect(find.text('3'), findsNothing);
    expect(find.text('Accounts reached'), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, -700));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('India'), findsOneWidget);
  });

  // ------------------------------------------------------------ sign up
  testWidgets('sign up starts with choosing a language', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(const ChooseLanguageScreen()));
    await tester.pump();
    expect(find.text('Choose your\nlanguage'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('lang-search')), 'hin');
    await tester.pump();
    expect(find.byKey(const ValueKey('lang-hi')), findsOneWidget);
    expect(find.byKey(const ValueKey('lang-en')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('lang-hi')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('lang-continue')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('country')), findsOneWidget);
    expect(find.textContaining('Hindi'), findsWidgets);
  });
}
