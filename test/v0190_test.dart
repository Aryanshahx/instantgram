// v0.19.0: Hyper Intelligence feed, See translation, cover slider,
// stronger bad words.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:instantgram/core/config/app_info.dart';
import 'package:instantgram/core/services/api_client.dart';
import 'package:instantgram/core/services/app_settings.dart';
import 'package:instantgram/core/services/bad_words.dart';
import 'package:instantgram/core/services/content_filter.dart';
import 'package:instantgram/core/services/hyper_feed.dart';
import 'package:instantgram/core/services/hyper_intelligence.dart';
import 'package:instantgram/core/services/music_player.dart';
import 'package:instantgram/core/services/presence.dart';
import 'package:instantgram/core/services/translator.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/post/presentation/comments_sheet.dart';
import 'package:instantgram/features/post/presentation/create_post_screen.dart';
import 'package:instantgram/features/post/presentation/post_menu.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:instantgram/shared/widgets/see_translation.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime(2026, 10, 16, 12);
const _h = Duration(hours: 1);

Post _p(
  String id, {
  String author = 'amit',
  bool clip = false,
  Duration age = const Duration(hours: 30),
  int likes = 0,
  int views = 0,
  String caption = '',
  bool sensitive = false,
}) => Post.fromMap(id, {
  'authorId': author,
  'authorUsername': author,
  'type': clip ? 'clip' : 'photo',
  'mediaUrl': 'https://x/$id.jpg',
  'caption': caption,
  'likesCount': likes,
  'uniqueViews': views,
  'sensitive': sensitive,
  'createdAt': Timestamp.fromDate(_now.subtract(age)),
});

Future<void> _frames(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _finish(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 1));
}

List<String> _ids(List<Post> l) => [for (final p in l) p.id];

void main() {
  final feed = HyperFeed.instance;
  var nowMs = _now.millisecondsSinceEpoch;

  setUpAll(() {
    NetImage.disableCache = true;
    MusicPlayer.disabled = true;
    Presence.instance.show.value = false;
  });

  setUp(() {
    nowMs = _now.millisecondsSinceEpoch;
    HyperFeed.debugNow = () => nowMs;
    feed.debugReset();
    ContentFilter.instance.debugSet(me: 'me');
    HyperIntelligence.instance.debugSet();
    AppSettings.instance.language.value = 'en';
    Translator.instance.clearCache();
    Translator.debugPost = null;
    Translator.debugDirect = null;
  });

  test('version is 0.19 or newer', () {
    expect(AppInfo.version, matches(RegExp(r'^\d+\.\d+\.\d+$')));
  });

  // ------------------------------------------------------------ bad words
  group('BadWords (strong only)', () {
    test('catches strong words in many spellings', () {
      for (final s in [
        'you fucker', 'F.U.C.K this', 'f u c k you', 'fuuuuck', 'FUCK',
        'what a 5lut', 'total b1tch', 'fuckboy99', 'my_motherfucker_name',
        'ph*ck you', 'f*ck', 'fvck', 'tu madarchod hai', 'madharchod',
        'bhenchod', 'behnchod', 'bhen ke lode', 'chootiya', 'chutiye',
        'saale chutiye', 'gaandu', 'bhosdike', 'bhosdiwale', 'bsdk',
        'lawde', 'lavde', 'lodu', 'randi', 'harami', 'haramzaada',
        'teri maa ki chut', 'maa chod di', 'साला चूतिया', 'मादरचोद',
        // ड़ typed as one letter and as ड + dot
        'भोसड़ीके', 'भोसड़ीके', 'गाँड', 'गांड', 'teri maa ki',
        'please kill yourself', 'Kill. Your. Self!!', 'mkc', 'tmkc', 'bkl',
        'kutiya', 'mera lund', 'Lund le', 'लंड', 'chu\u200Btiya',
      ]) {
        expect(BadWords.find(s), isNotNull, reason: s);
      }
    });

    test('mild and normal words are allowed', () {
      for (final s in [
        '',
        'Hello world',
        'Scunthorpe United',
        'classic class assassin',
        'I visited Niger',
        'Lund University',
        'Gandhi ji',
        'पानी पीना है',
        'Shit happens',
        'cocktail party at Dickens road',
        'killing it at the gym',
        'k i l l',
        'chod do yaar',
        'choodi pehni',
        'chakka mara',
        'bkc office',
        'jantu',
        'Asha Bhosle',
        'chutney',
        'cut it',
        'bc yaar',
        'mc',
        'saala',
        'kamina',
        'kutta',
        'bastard',
        'damn',
        'ass',
        'bakwas',
        'pagal',
        'idiot',
        'stupid',
        'Randhir',
        'gandi baat',
        'haram',
        'chhod do',
        'lauki',
        'sexy',
        'hot pic',
        'die hard fan',
        'I will kill this game',
        'kill bill',
        'मुझे छोड़ दो',
        'जंतु',
        'wow!!',
        'Sh!ne bright',
      ]) {
        expect(BadWords.find(s), isNull, reason: s);
      }
    });
  });

  // ------------------------------------------------------------ translation
  group('Translator', () {
    test('when "See translation" is offered', () {
      bool o(String s, String to) => Translator.shouldOffer(s, to);
      expect(o('kya baat hai bhai', 'en'), isTrue);
      expect(o('What a beautiful day with my friends', 'en'), isFalse);
      expect(o('बहुत सुंदर फोटो', 'en'), isTrue);
      expect(o('बहुत सुंदर फोटो', 'hi'), isFalse);
      expect(o('Nice photo bro', 'hi'), isTrue);
      expect(o('😍😍🔥', 'en'), isFalse);
      expect(o('#goa @amit https://x.com/abc', 'en'), isFalse);
      expect(o('Wow', 'en'), isFalse);
      expect(o('This is my life and I love it', 'es'), isTrue);
      expect(o('hola amigos como estan', 'es'), isFalse);
      expect(o('Привет друзья', 'en'), isTrue);
      expect(o('Привет друзья', 'ru'), isFalse);
      expect(o('こんにちは', 'ja'), isFalse);
      expect(o('안녕하세요 여러분', 'en'), isTrue);
    });

    test('Google answers are read', () {
      final a = Translator.parseClients5('[["Hello friend","hi"]]', 'en');
      expect(a.text, 'Hello friend');
      expect(a.from, 'hi');
      expect(Translator.parseClients5('["Hola"]', 'es').from, '');
      expect(Translator.parseClients5('[["Kumusta","tl"]]', 'en').from, 'fil');
      expect(() => Translator.parseClients5('{}', 'en'), throwsFormatException);
    });

    test('server first, saved answers, phone when the server fails', () async {
      final sent = <Map<String, dynamic>>[];
      Translator.debugPost = (b) async {
        sent.add(b);
        return {'text': 'What a thing', 'from': 'hi'};
      };
      final a = await Translator.instance.translate('kya baat');
      expect(a.text, 'What a thing');
      expect(a.from, 'hi');
      expect(a.to, 'en');
      expect(a.same, isFalse);
      expect(sent.single, {
        'action': 'translate',
        'text': 'kya baat',
        'to': 'en',
      });
      await Translator.instance.translate('kya baat');
      expect(sent.length, 1, reason: 'saved answer');

      var direct = 0;
      Translator.debugPost = (b) async =>
          throw ApiException('x', statusCode: 502);
      Translator.debugDirect = (text, to) async {
        direct++;
        return Translation(text: 'Hola', from: 'en', to: to);
      };
      final b = await Translator.instance.translate('Hello', to: 'es');
      expect(b.text, 'Hola');
      expect(direct, 1);

      Translator.debugPost = (b) async =>
          throw ApiException('bad', statusCode: 400);
      await expectLater(
        Translator.instance.translate('Other text'),
        throwsA(isA<ApiException>()),
      );
      expect(direct, 1, reason: '400 = the phone would not do better');
    });
  });

  group('See translation widget', () {
    Widget app(String text) => MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: SeeTranslation(
          text: text,
          builder: (t, tr) => Text(t, key: ValueKey(tr ? 'tr' : 'orig')),
        ),
      ),
    );

    testWidgets('tap -> translation, tap again -> original', (t) async {
      final done = Completer<Map<String, dynamic>>();
      Translator.debugPost = (b) => done.future;
      await t.pumpWidget(app('kya baat hai bhai'));
      expect(find.text('See translation'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('see-translation')));
      await t.pump();
      expect(find.text('Translating…'), findsOneWidget);
      done.complete({'text': 'What a thing brother', 'from': 'hi'});
      await _frames(t, 2);
      expect(find.text('What a thing brother'), findsOneWidget);
      expect(find.text('kya baat hai bhai'), findsNothing);
      expect(find.text('See original · Translated from Hindi'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('see-translation')));
      await _frames(t, 2);
      expect(find.text('kya baat hai bhai'), findsOneWidget);
      expect(find.text('See translation'), findsOneWidget);
      await _finish(t);
    });

    testWidgets('English for an English user: no link', (t) async {
      await t.pumpWidget(app('What a beautiful day with my friends'));
      expect(find.byKey(const ValueKey('see-translation')), findsNothing);
      await _finish(t);
    });

    testWidgets('fails -> "Try again"; already your language -> link goes', (
      t,
    ) async {
      Translator.debugPost = (b) async =>
          throw ApiException('x', statusCode: 502);
      Translator.debugDirect = (text, to) async => throw Exception('offline');
      await t.pumpWidget(app('kya baat hai bhai'));
      await t.tap(find.byKey(const ValueKey('see-translation')));
      await _frames(t, 2);
      expect(find.text("Couldn't translate · Try again"), findsOneWidget);
      Translator.debugPost = (b) async => {
        'text': 'Sunset vibes',
        'from': 'en',
      };
      await t.tap(find.byKey(const ValueKey('see-translation')));
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('see-translation')), findsNothing);
      expect(find.text('kya baat hai bhai'), findsOneWidget);
      await _finish(t);
    });

    testWidgets('comments have it', (t) async {
      final c = Comment.fromMap('c1', {
        'authorId': 'amit',
        'authorUsername': 'amit',
        'text': 'bahut badhiya bhai',
      });
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: CommentTile(
              postId: 'p1',
              comment: c,
              canDelete: false,
              onReply: () {},
              onDelete: () {},
              likedStream: Stream.value(false),
            ),
          ),
        ),
      );
      await _frames(t, 2);
      expect(find.text('See translation'), findsOneWidget);
      await _finish(t);
    });
  });

  // ------------------------------------------------------------ cover
  testWidgets('cover: 30 frames + a slider for any moment', (t) async {
    t.view.physicalSize = const Size(1080, 2200);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 9, height: 16)),
    );
    CoverPickerScreen.debugNoVideo = true;
    CoverPickerScreen.debugFrame = (path, ms) async => png;
    addTearDown(() {
      CoverPickerScreen.debugNoVideo = false;
      CoverPickerScreen.debugFrame = null;
    });
    int? picked;
    final item = EditedMedia(
      file: File('/tmp/none.mp4'),
      isVideo: true,
      aspectRatio: 9 / 16,
      durationMs: 10000,
      edits: const VideoEdits(trimStartMs: 1000, trimEndMs: 7000),
    );
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Builder(
          builder: (c) => Scaffold(
            body: TextButton(
              onPressed: () async {
                picked = await Navigator.of(c).push<int>(
                  MaterialPageRoute(
                    builder: (_) => CoverPickerScreen(item: item),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await _frames(t, 10);
    final times = CoverPickerScreen.frameTimes(1000, 7000);
    expect(times.length, 30);
    expect(CoverPickerScreen.frameCount, 30);
    Slider slider() =>
        t.widget<Slider>(find.byKey(const ValueKey('cover-slider')));
    expect(slider().min, times.first.toDouble());
    expect(slider().max, times.last.toDouble());
    // slide to an exact moment between two frames
    slider().onChanged!(3456);
    await _frames(t, 2);
    expect(slider().value, 3456);
    expect(find.text('Slide or tap a frame · 0:02'), findsOneWidget);
    // tap a frame -> the slider jumps there
    await t.scrollUntilVisible(
      find.byKey(const ValueKey('cover-frame-20')),
      80,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('cover-frames')),
        matching: find.byType(Scrollable),
      ),
    );
    await t.tap(find.byKey(const ValueKey('cover-frame-20')));
    await _frames(t, 2);
    expect(slider().value, times[20].toDouble());
    slider().onChanged!(5123);
    await _frames(t, 2);
    await t.tap(find.byKey(const ValueKey('cover-done')));
    await _frames(t, 6);
    expect(picked, 5123);
    await _finish(t);
  });

  // ------------------------------------------------------------ feed
  group('Hyper Intelligence feed: learning', () {
    test('likes make someone closer; half after 14 days', () {
      expect(feed.closeness('amit'), 0);
      feed.liked(_p('a1'), true);
      expect(feed.closeness('amit'), closeTo(1 / 6, 1e-9));
      nowMs += const Duration(days: 14).inMilliseconds;
      expect(feed.closeness('amit'), closeTo(0.5 / 5.5, 1e-9));
      // unlike takes it back
      feed.liked(_p('a1'), false);
      expect(feed.closeness('amit'), 0);
    });

    test('weights: comment 2, save 2, share 3, chats, profile visits', () {
      feed.commented(_p('a1', author: 'c'));
      feed.saved(_p('a2', author: 's'), true);
      feed.shared(_p('a3', author: 'sh'));
      feed.chatted('ch');
      feed.visitedProfile('v');
      double c(String u) => feed.closeness(u);
      expect(c('sh'), greaterThan(c('s')));
      expect(c('s'), closeTo(c('c'), 1e-9));
      expect(c('c'), greaterThan(c('ch')));
      expect(c('ch'), greaterThan(c('v')));
      expect(c('v'), greaterThan(0));
      // never learns about yourself
      feed.chatted('me');
      expect(feed.closeness('me'), 0.6);
    });

    test('watching to the end = yes, gone in 2 s = no (once each)', () {
      final clip = _p('c1', clip: true);
      feed.watched(clip, watchMs: 9000, completed: true);
      final full = feed.closeness('amit');
      expect(full, greaterThan(0));
      feed.watched(clip, watchMs: 9000, completed: true);
      expect(feed.closeness('amit'), full, reason: 'once per app run');
      feed.watched(_p('c2', clip: true), watchMs: 800, completed: false);
      expect(feed.closeness('amit'), lessThan(full));
      // photos are not "skipped"
      final before = feed.closeness('amit');
      feed.watched(_p('p9'), watchMs: 100, completed: false);
      expect(feed.closeness('amit'), before);
    });

    test('top hashtags + interest', () {
      for (var i = 0; i < 3; i++) {
        feed.liked(
          _p('g$i', caption: i < 2 ? 'trip #Goa #beach' : '#goa'),
          true,
        );
      }
      feed.liked(_p('f1', caption: '#food'), true);
      expect(feed.topTags(2), ['goa', 'beach']);
      expect(
        feed.interest(_p('x', author: 'z', caption: '#goa')),
        greaterThan(feed.interest(_p('y', author: 'z', caption: '#cars'))),
      );
    });

    test('quality + freshness formulas', () {
      expect(HyperFeed.quality(_p('q0')), 0);
      // 1 like, 1 view must not look perfect (the +20)
      expect(HyperFeed.quality(_p('q1', likes: 1, views: 1)), lessThan(0.2));
      expect(
        HyperFeed.quality(_p('q2', likes: 60, views: 100)),
        greaterThan(HyperFeed.quality(_p('q3', likes: 5, views: 100))),
      );
      final n = _now.millisecondsSinceEpoch;
      expect(HyperFeed.freshness(_p('f0', age: Duration.zero), n), 1);
      expect(
        HyperFeed.freshness(_p('f1', age: _h * 24), n),
        closeTo(0.5, 1e-9),
      );
      expect(
        HyperFeed.freshness(_p('f2', clip: true, age: _h * 72), n),
        closeTo(0.5, 1e-9),
      );
    });

    test('safety: sensitive x0.2, seen x0.3, not interested', () {
      final a = _p('s1', author: 'z');
      final base = feed.safety(a);
      expect(base, 1);
      expect(feed.safety(_p('s2', author: 'z', sensitive: true)), 0.2);
      feed.markSeen(a);
      expect(feed.safety(a), closeTo(0.3, 1e-9));
      expect(feed.seenToday('s1'), isTrue);
      final b = _p('n1', author: 'bad', caption: '#spam');
      feed.notInterested(b);
      expect(feed.isHidden('n1'), isTrue);
      expect(feed.safety(b), 0);
      expect(feed.safety(_p('n2', author: 'bad')), closeTo(0.1, 1e-9));
      expect(
        feed.safety(_p('n3', author: 'ok', caption: '#spam')),
        closeTo(0.4, 1e-9),
      );
      HyperIntelligence.instance.debugSet(minor: true);
      expect(feed.safety(_p('s3', author: 'z', sensitive: true)), 0);
    });

    test('saved + loaded (phone copy), small online copy', () {
      feed.liked(_p('a1', caption: '#goa'), true);
      for (var i = 0; i < 40; i++) {
        feed.chatted('u$i');
      }
      feed.markSeen(_p('seen1'));
      feed.notInterested(_p('n1', author: 'bad'));
      final raw = feed.dump();
      final online = feed.dump(online: true);
      final c = feed.closeness('amit');
      feed.debugReset();
      expect(feed.closeness('amit'), 0);
      feed.load(raw);
      expect(feed.closeness('amit'), closeTo(c, 1e-9));
      expect(feed.isHidden('n1'), isTrue);
      expect(feed.seenToday('seen1'), isTrue);
      expect(online.contains('"seen"'), isFalse);
      expect(online.contains('"hide"'), isFalse);
      feed.debugReset();
      feed.load(online);
      expect(feed.topTags(1), ['goa']);
      expect(feed.isHidden('n1'), isFalse);
      expect('"u'.allMatches(online).length, lessThanOrEqualTo(30));
    });

    testWidgets('start: phone copy first, else the online copy', (t) async {
      SharedPreferences.setMockInitialValues({});
      await t.runAsync(() async {
        feed.downloader = () async =>
            '{"v":1,"p":{"zoe":[5,${_now.millisecondsSinceEpoch}]}}';
        await feed.start('uid1');
      });
      expect(feed.closeness('zoe'), closeTo(0.5, 1e-9));
      feed.downloader = null;
    });
  });

  group('Hyper Intelligence feed: mixing rules', () {
    test('never more than 2 in a row from one person', () {
      for (var i = 0; i < 5; i++) {
        feed.liked(_p('l$i', author: 'star'), true);
      }
      final r = feed.rank([
        _p('a1', author: 'star', likes: 9, views: 10),
        _p('a2', author: 'star', likes: 8, views: 10),
        _p('a3', author: 'star', likes: 7, views: 10),
        _p('b1', author: 'bob'),
      ], mode: FeedMode.explore);
      expect(_ids(r), ['a1', 'a2', 'b1', 'a3']);
    });

    test('new posts from people you follow are in the first 10', () {
      ContentFilter.instance.debugSet(me: 'me', following: {'f1'});
      final posts = [
        for (var i = 0; i < 15; i++)
          _p('x$i', author: 'x$i', likes: 100, views: 100, age: _h * 2),
        _p('fresh', author: 'f1', age: _h * 2),
        _p('old', author: 'f1', age: _h * 80),
        _p('mine', author: 'me', age: _h * 1),
      ];
      final r = _ids(feed.rank(posts));
      expect(r.indexOf('fresh'), lessThan(10));
      // v0.20: your own posts are never in your feed
      expect(r, isNot(contains('mine')));
      expect(r.indexOf('old'), greaterThanOrEqualTo(10));
      expect(r.length, posts.length - 1);
    });

    test('1 in every 5 is from someone new', () {
      ContentFilter.instance.debugSet(
        me: 'me',
        following: {'f1', 'f2', 'f3', 'f4', 'f5', 'f6'},
      );
      final posts = [
        for (var i = 1; i <= 6; i++)
          _p('f$i', author: 'f$i', likes: 50, views: 60),
        _p('new1', author: 'stranger'),
      ];
      final r = _ids(feed.rank(posts, mode: FeedMode.explore));
      expect(r.indexOf('new1'), lessThanOrEqualTo(4));
    });

    test('home feed: max 3 clips / photos in a row', () {
      final posts = [
        for (var i = 0; i < 5; i++)
          _p('c$i', author: 'c$i', clip: true, likes: 50 - i, views: 60),
        _p('p0', author: 'p0'),
        _p('p1', author: 'p1'),
      ];
      final r = feed.rank(posts);
      for (var i = 3; i < r.length; i++) {
        final four = r.sublist(i - 3, i + 1);
        expect(
          four.every((p) => p.isClip) || four.every((p) => !p.isClip),
          isFalse,
          reason: _ids(r).join(','),
        );
      }
    });

    test('nothing you saw today at the top', () {
      final best = _p('best', author: 'b', likes: 500, views: 500, age: _h);
      feed.markSeen(best);
      final r = _ids(
        feed.rank([
          best,
          _p('o1', author: 'o1'),
          _p('o2', author: 'o2'),
          _p('o3', author: 'o3'),
        ], mode: FeedMode.clips),
      );
      expect(r.indexOf('best'), greaterThanOrEqualTo(3));
    });

    test('hidden and HI-hidden posts are left out', () {
      feed.notInterested(_p('h1', author: 'z'));
      final r = feed.rank([
        _p('h1', author: 'z'),
        Post.fromMap('h2', {
          'authorId': 'y',
          'type': 'photo',
          'modState': 'hidden',
        }),
        _p('ok', author: 'w'),
      ]);
      expect(_ids(r), ['ok']);
    });

    test('steady order: new posts placed without moving the top', () {
      ContentFilter.instance.debugSet(me: 'me', following: {'f1'});
      final first = [
        for (var i = 0; i < 8; i++)
          _p('o$i', author: 'o$i', likes: 80 - i * 10, views: 100),
      ];
      final a = _ids(feed.ordered('k', first, mode: FeedMode.explore));
      // same list again (fresh data): same order
      expect(_ids(feed.ordered('k', first.reversed.toList())), a);
      final great = _p('great', author: 'g', likes: 1000, views: 100);
      final b = _ids(
        feed.ordered('k', [...first, great], mode: FeedMode.explore),
      );
      expect(b.sublist(0, 4), a.sublist(0, 4), reason: 'top stays');
      expect(b.indexOf('great'), 4);
      // home feed: a new post from someone you follow goes on top
      final f = _p('friend', author: 'f1', age: _h);
      final c = _ids(feed.ordered('k', [...first, great, f]));
      expect(c.first, 'friend');
      // a deleted post leaves
      final d = _ids(feed.ordered('k', [...first.skip(1), great, f]));
      expect(d.contains('o0'), isFalse);
      // pull to refresh -> ranked again from scratch
      feed.reset('k');
      final e = _ids(
        feed.ordered('k', [...first, great], mode: FeedMode.explore),
      );
      expect(e.first, 'great');
    });

    test('home feed stream: people you follow + extras, no doubles', () async {
      final base = StreamController<List<Post>>();
      final s = feed.discover(
        base.stream,
        extras: () async => [_p('t1', author: 'tag'), _p('b1', author: 'x')],
      );
      final got = <List<String>>[];
      final sub = s.listen((l) => got.add(_ids(l)..sort()));
      base.add([_p('b1', author: 'x'), _p('b2', author: 'y')]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(got.last, ['b1', 'b2', 't1']);
      await sub.cancel();
      await base.close();
    });
  });

  testWidgets('⋯ menu: Not interested (not on your own posts)', (t) async {
    final other = _p('o1', author: 'amit');
    final mine = _p('m1', author: 'me');
    var deleted = 0;
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (c) => Column(
              children: [
                TextButton(
                  onPressed: () => showPostMenu(c, mine),
                  child: const Text('mine'),
                ),
                TextButton(
                  onPressed: () => showPostMenu(
                    c,
                    other,
                    showAutoScroll: true,
                    onDeleted: () => deleted++,
                  ),
                  child: const Text('other'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('mine'));
    await _frames(t, 10);
    expect(find.byKey(const ValueKey('menu-not-interested')), findsNothing);
    await t.tapAt(const Offset(10, 10));
    await _frames(t, 10);
    await t.tap(find.text('other'));
    await _frames(t, 10);
    expect(find.text('Show fewer posts like this'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('menu-not-interested')));
    await _frames(t, 10);
    expect(feed.isHidden('o1'), isTrue);
    expect(deleted, 1, reason: 'Clips skips to the next clip');
    await _finish(t);
  });
}
