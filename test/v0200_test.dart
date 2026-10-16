// v0.20.0: analytics fixes, long-press Delete, comment order, translation,
// no own posts in your feed, trending, reports, strikes, spam limits.
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/config/app_info.dart';
import 'package:instantgram/core/services/app_settings.dart';
import 'package:instantgram/core/services/content_filter.dart';
import 'package:instantgram/core/services/hyper_feed.dart';
import 'package:instantgram/core/services/hyper_intelligence.dart';
import 'package:instantgram/core/services/spam_guard.dart';
import 'package:instantgram/core/services/translator.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/insights/owner_sheet.dart';
import 'package:instantgram/features/insights/post_insights.dart';
import 'package:instantgram/features/post/data/post_repository.dart';
import 'package:instantgram/features/post/data/report_repository.dart';
import 'package:instantgram/features/post/presentation/create_post_screen.dart';
import 'package:instantgram/features/post/presentation/post_menu.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime(2026, 10, 16, 12);
const _h = Duration(hours: 1);

Post _p(
  String id, {
  String author = 'amit',
  bool clip = false,
  Duration age = const Duration(hours: 30),
  int likes = 0,
  int comments = 0,
  int views = 0,
}) => Post.fromMap(id, {
  'authorId': author,
  'authorUsername': author,
  'type': clip ? 'clip' : 'photo',
  'mediaUrl': clip ? 'https://x/$id.mp4' : 'https://x/$id.jpg',
  if (clip) 'media': [
    {'type': 'video', 'url': 'https://x/$id.mp4'},
  ],
  'likesCount': likes,
  'commentsCount': comments,
  'uniqueViews': views,
  'createdAt': Timestamp.fromDate(_now.subtract(age)),
});

Comment _c(
  String id, {
  String author = 'x',
  int likes = 0,
  int replies = 0,
  int minsAgo = 10,
}) => Comment.fromMap(id, {
  'authorId': author,
  'authorUsername': author,
  'text': 'c $id',
  'likesCount': likes,
  'repliesCount': replies,
  'createdAt': Timestamp.fromDate(
    _now.subtract(Duration(minutes: minsAgo)),
  ),
});

(Comment, List<Comment>) _g(Comment c) => (c, const <Comment>[]);

List<String> _ids(List<(Comment, List<Comment>)> l) => [
  for (final g in l) g.$1.id,
];

Future<void> _frames(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() {
    NetImage.disableCache = true;
    SharedPreferences.setMockInitialValues({});
  });

  test('version is 0.20 or newer', () {
    expect(AppInfo.version, matches(RegExp(r'^0\.(2\d|[3-9]\d)\.\d+$')));
  });

  // ------------------------------------------------ watched to the end
  group('VideoTime.reachedEnd', () {
    test('near the end or after a loop', () {
      bool end(int pos, int last) => VideoTime.reachedEnd(
        pos: pos,
        lastPos: last,
        startMs: 0,
        endMs: 10000,
      );
      expect(end(5000, 4800), isFalse);
      expect(end(9400, 9200), isTrue); // within 700 ms of the end
      // looped: was at 9.0 s, now back at 0.2 s (the last frame was missed)
      expect(end(200, 9000), isTrue);
      // jumped back by hand from the middle: not the end
      expect(end(200, 6000), isFalse);
      // trimmed clip 2 s .. 8 s
      expect(
        VideoTime.reachedEnd(
          pos: 7500,
          lastPos: 7300,
          startMs: 2000,
          endMs: 8000,
        ),
        isTrue,
      );
    });
  });

  // ------------------------------------------------ analytics numbers
  group('analytics', () {
    test('engagement never over 100%, completion only from watch data', () {
      final p = _p('p1', clip: true, likes: 5, comments: 4, views: 2);
      final d = PostInsights.from(p, [
        {'_id': 'a', 'count': 1, 'watchMs': 9000, 'completed': true},
        {'_id': 'b', 'count': 1}, // old view: no watch data
      ], now: _now);
      expect(d.interactions, 9);
      expect(d.engagementRate, lessThanOrEqualTo(1.0));
      expect(d.engagementRate, 1.0);
      expect(d.watchDocs, 1);
      expect(d.completionRate, 1.0);
    });

    test('account: older posts without view docs still count', () {
      final posts = [
        _p('new', likes: 1, views: 10, age: _h),
        _p('old', likes: 2, views: 90, age: const Duration(days: 40)),
      ];
      // only the newest post has view docs (Dashboard loads 30)
      final d = PostInsights.fromMany(posts, [
        [
          {'_id': 'u1', 'count': 1},
        ],
      ], now: _now);
      expect(d.postCount, 2);
      expect(d.views, 100);
      expect(d.reach, 90);
      // 3 interactions / (10 + 90) accounts reached
      expect(d.engagementRate, closeTo(0.03, 0.0001));
      expect(d.watchDocs, 0);
    });

    test('no reach but likes: still a sane number', () {
      final d = PostInsights.from(_p('p', likes: 3), const [], now: _now);
      expect(d.engagementRate, 1.0);
      expect(d.completionRate, 0);
    });
  });

  // ------------------------------------------------ comment order
  group('CommentOrder', () {
    test('mine first, then pinned, then likes + replies', () {
      final o = CommentOrder();
      final r = o.apply([
        _g(_c('a', likes: 1)),
        _g(_c('b', likes: 10)),
        _g(_c('c', replies: 3)), // 6 points
        _g(_c('m1', author: 'me', minsAgo: 50)),
        _g(_c('m2', author: 'me', minsAgo: 5)),
        _g(_c('pin', likes: 0)),
      ], me: 'me', pinned: 'pin');
      expect(_ids(r), ['m2', 'm1', 'pin', 'b', 'c', 'a']);
    });

    test('order stays while open; new comments find their place', () {
      final o = CommentOrder();
      o.apply([_g(_c('a', likes: 5)), _g(_c('b', likes: 2))], me: 'me');
      // b gets many likes while the sheet is open: no jumping
      var r = o.apply([
        _g(_c('a', likes: 5)),
        _g(_c('b', likes: 50)),
      ], me: 'me');
      expect(_ids(r), ['a', 'b']);
      // new comment from someone with 3 likes goes between a and b
      r = o.apply([
        _g(_c('a', likes: 5)),
        _g(_c('b', likes: 2)),
        _g(_c('n', likes: 3, minsAgo: 1)),
      ], me: 'me');
      expect(_ids(r), ['a', 'n', 'b']);
      // my new comment goes on top
      r = o.apply([
        _g(_c('a', likes: 5)),
        _g(_c('b', likes: 2)),
        _g(_c('n', likes: 3, minsAgo: 1)),
        _g(_c('mine', author: 'me', minsAgo: 0)),
      ], me: 'me');
      expect(_ids(r).first, 'mine');
      // opened again: sorted fresh
      o.reset();
      r = o.apply([
        _g(_c('a', likes: 5)),
        _g(_c('b', likes: 50)),
      ], me: 'me');
      expect(_ids(r), ['b', 'a']);
    });

    test('score = likes + 2 per reply', () {
      expect(CommentOrder.score(_c('x', likes: 3, replies: 2), 0), 7);
      expect(CommentOrder.score(_c('x', likes: 1), 4), 9);
    });
  });

  // ------------------------------------------------ translation
  group('translation', () {
    setUp(() {
      Translator.instance.clearCache();
      Translator.debugPost = null;
      Translator.debugDirect = null;
      Translator.debugHttp = null;
      AppSettings.instance.language.value = 'en';
    });
    tearDown(() {
      Translator.debugPost = null;
      Translator.debugHttp = null;
    });

    test('emojis, @names, links and new lines are kept', () {
      const text = 'Bahut sundar 😍 @amit\nwww.x.com bhai #goa';
      final parts = Translator.splitText(text);
      expect(
        [
          for (final p in parts)
            if (p.keep == null) p.core,
        ],
        ['Bahut sundar', 'bhai'],
      );
      expect(
        Translator.joinText(parts, ['very beautiful', 'brother']),
        'Very beautiful 😍 @amit\nwww.x.com brother #goa',
      );
    });

    test('all kinds of emojis are kept as they are', () {
      const text = 'Wah ❤️ bhai 👍🏽 India 🇮🇳 ✨ dil 🫶 ok ✔ #1️⃣ 👨‍👩‍👧 end';
      final parts = Translator.splitText(text);
      final cores = [
        for (final p in parts)
          if (p.keep == null) p.core,
      ];
      expect(cores, ['Wah', 'bhai', 'India', 'dil', 'ok', 'end']);
      expect(Translator.joinText(parts, cores), text);
    });

    test('which language is written in English letters', () {
      expect(Translator.guessLatin('kya baat hai bhai bahut accha'), 'hinglish');
      expect(Translator.guessLatin('this is a really nice photo'), 'en');
      expect(Translator.guessLatin('que bonito es esto amigo'), 'es');
    });

    test('when "See translation" is shown', () {
      // Hinglish: yes for English readers, no for Hindi readers
      expect(Translator.shouldOffer('kya baat hai bhai bahut accha', 'en'), isTrue);
      expect(Translator.shouldOffer('kya baat hai bhai bahut accha', 'hi'), isFalse);
      // English for English readers: no; for Hindi / Spanish readers: yes
      expect(Translator.shouldOffer('this is a really nice photo', 'en'), isFalse);
      expect(Translator.shouldOffer('this is a really nice photo', 'hi'), isTrue);
      expect(Translator.shouldOffer('this is a really nice photo', 'es'), isTrue);
      // Hindi letters
      expect(Translator.shouldOffer('बहुत सुंदर फोटो है', 'en'), isTrue);
      expect(Translator.shouldOffer('बहुत सुंदर फोटो है', 'hi'), isFalse);
      // emojis / names only
      expect(Translator.shouldOffer('😍😍 @amit', 'en'), isFalse);
      expect(Translator.shouldOffer('ok', 'hi'), isFalse);
    });

    test('server down -> phone asks Google: one call for many lines', () async {
      final calls = <String>[];
      Translator.debugPost = (b) async => throw Exception('offline');
      Translator.debugHttp = (url, headers, body) async {
        calls.add(url);
        expect(url, contains('clients5'));
        expect(url, contains('tl=en'));
        final qs = body.split('&').map((e) => Uri.decodeQueryComponent(e.substring(2))).toList();
        expect(qs, ['Bahut sundar', 'kya baat hai']);
        return jsonEncode([
          ['very beautiful', 'hi'],
          ['what a thing', 'hi'],
        ]);
      };
      final t = await Translator.instance.translate(
        'Bahut sundar 😍\nkya baat hai',
        to: 'en',
      );
      expect(t.text, 'Very beautiful 😍\nwhat a thing');
      expect(t.from, 'hi');
      expect(calls.length, 1);
    });

    test('clients5 blocked -> Google website translator', () async {
      final calls = <String>[];
      Translator.debugPost = (b) async => throw Exception('offline');
      Translator.debugHttp = (url, headers, body) async {
        calls.add(url);
        if (url.contains('clients5')) return '<html>Sorry</html>';
        expect(headers['Content-Type'], 'application/json+protobuf');
        expect(jsonDecode(body), [
          [
            ['Tom &amp; Jerry', 'acha'],
            'auto',
            'en',
          ],
          'wt_lib',
        ]);
        return jsonEncode([
          ['Tom &amp; Jerry', 'good'],
          ['en', 'hi'],
        ]);
      };
      final t = await Translator.direct('Tom & Jerry 🔥 acha', 'en');
      expect(t.text, 'Tom & Jerry 🔥 good');
      expect(calls.length, 2);
    });
  });

  // ------------------------------------------------ feed: never your own
  group('feed', () {
    setUp(() {
      HyperFeed.debugNow = () => _now.millisecondsSinceEpoch;
      HyperFeed.instance.debugReset();
      HyperIntelligence.instance.debugSet();
      ContentFilter.instance.debugSet(me: 'me', following: {'f1'});
    });

    test('your own posts and clips are never in your feeds', () {
      final posts = [
        _p('a', author: 'f1', age: _h),
        _p('mine1', author: 'me', age: _h),
        _p('b', author: 'x', likes: 9, views: 10),
        _p('mine2', author: 'me', clip: true, age: _h),
        _p('c', author: 'y', clip: true, likes: 3, views: 5),
      ];
      for (final mode in FeedMode.values) {
        final r = [for (final p in HyperFeed.instance.rank(posts, mode: mode)) p.id];
        expect(r, isNot(contains('mine1')), reason: '$mode');
        expect(r, isNot(contains('mine2')), reason: '$mode');
        expect(r.length, 3, reason: '$mode');
      }
    });
  });

  // ------------------------------------------------ long-press Delete
  group('delete', () {
    tearDown(() => PostRepository.debugDelete = null);

    Future<BuildContext> host(WidgetTester t) async {
      late BuildContext ctx;
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (c) {
                ctx = c;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      return ctx;
    }

    testWidgets('Cancel keeps it, Delete deletes', (t) async {
      final deleted = <String>[];
      var told = 0;
      PostRepository.debugDelete = (p) async => deleted.add(p.id);
      final ctx = await host(t);
      final post = _p('p1', author: 'me', clip: true);
      var f = confirmDeletePost(ctx, post, onDeleted: () => told++);
      await _frames(t);
      expect(find.text('Delete this clip?'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('delete-cancel')));
      await _frames(t);
      expect(await f, isFalse);
      expect(deleted, isEmpty);
      f = confirmDeletePost(ctx, post, onDeleted: () => told++);
      await _frames(t);
      await t.tap(find.byKey(const ValueKey('delete-confirm')));
      await _frames(t);
      expect(await f, isTrue);
      expect(deleted, ['p1']);
      expect(told, 1);
      expect(find.text('Deleted'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
    });

    testWidgets('a failed delete says why', (t) async {
      PostRepository.debugDelete = (p) async => throw Exception('No internet');
      final ctx = await host(t);
      final f = confirmDeletePost(ctx, _p('p1', author: 'me'));
      await _frames(t);
      expect(find.text('Delete this post?'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('delete-confirm')));
      await _frames(t);
      expect(await f, isFalse);
      expect(find.textContaining('No internet'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
    });

    testWidgets('long-press sheet on your own post has Delete', (t) async {
      final deleted = <String>[];
      var told = 0;
      PostRepository.debugDelete = (p) async => deleted.add(p.id);
      final ctx = await host(t);
      showOwnerQuickSheet(ctx, _p('p9', author: 'me'), onDeleted: () => told++);
      await _frames(t, 12);
      expect(find.byKey(const ValueKey('owner-analytics')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('owner-delete')));
      await _frames(t, 12);
      await t.tap(find.byKey(const ValueKey('delete-confirm')));
      await _frames(t);
      expect(deleted, ['p9']);
      expect(told, 1);
      await t.pump(const Duration(seconds: 5));
    });
  });

  // ------------------------------------------------ reports + strikes
  group('safety', () {
    tearDown(() {
      PostRepository.debugBlockedUntil = null;
      SpamGuard.debugNow = null;
      SpamGuard.debugCreated = null;
    });

    test('"Child safety" is a report reason', () {
      final titles = [for (final r in kReportReasons) r.title];
      expect(titles, contains(kChildSafetyReason));
      expect(titles.first, 'Spam');
      expect(titles.last, 'Something else');
    });

    test('2 strikes: no posting until the date', () async {
      SpamGuard.instance.debugReset();
      SpamGuard.debugCreated = DateTime(2025);
      PostRepository.debugBlockedUntil = () async => DateTime(2026, 10, 23, 9);
      final why = await postingStopReason(isStory: true);
      expect(why, contains('You can post again on 23 Oct 2026'));
      PostRepository.debugBlockedUntil = () async => null;
      expect(await postingStopReason(isStory: false), isNull);
    });
  });

  // ------------------------------------------------ spam limits
  group('SpamGuard', () {
    var nowMs = _now.millisecondsSinceEpoch;
    final g = SpamGuard.instance;
    setUp(() {
      nowMs = _now.millisecondsSinceEpoch;
      SpamGuard.debugNow = () => nowMs;
      g.debugReset();
    });
    tearDown(() {
      SpamGuard.debugNow = null;
      SpamGuard.debugCreated = null;
    });

    test('new account: 20 comments an hour, no links for 7 days', () {
      SpamGuard.debugCreated = _now.subtract(const Duration(hours: 3));
      expect(g.isNew, isTrue);
      expect(g.checkComment('see www.spam.com'), contains('links'));
      expect(g.checkComment('nice https://x.co/a'), contains('links'));
      for (var i = 0; i < 20; i++) {
        expect(g.checkComment('comment number $i'), isNull);
        g.recordComment('comment number $i');
      }
      expect(g.checkComment('one more'), contains('too fast'));
      nowMs += const Duration(minutes: 61).inMilliseconds;
      expect(g.checkComment('one more'), isNull);
      // 5 days old: not "new" any more, but still no links
      SpamGuard.debugCreated = _now.subtract(const Duration(days: 5));
      expect(g.isNew, isFalse);
      expect(g.checkComment('visit mysite.in'), contains('links'));
      SpamGuard.debugCreated = _now.subtract(const Duration(days: 8));
      expect(g.checkComment('visit mysite.in'), isNull);
    });

    test('the same comment again and again is stopped', () {
      SpamGuard.debugCreated = DateTime(2025);
      for (var i = 0; i < 3; i++) {
        expect(g.checkComment('Follow me please!!'), isNull);
        g.recordComment('Follow me please!!');
      }
      expect(g.checkComment('follow  ME please!!'), contains('many times'));
      // short ones like "nice" are fine
      for (var i = 0; i < 5; i++) {
        g.recordComment('nice');
      }
      expect(g.checkComment('nice'), isNull);
      nowMs += const Duration(minutes: 61).inMilliseconds;
      expect(g.checkComment('Follow me please!!'), isNull);
    });

    test('everyone: 60 comments an hour, 200 follows a day', () {
      SpamGuard.debugCreated = DateTime(2025);
      for (var i = 0; i < 60; i++) {
        g.recordComment('text $i');
      }
      expect(g.checkComment('x y z'), isNotNull);
      for (var i = 0; i < 199; i++) {
        g.recordFollow();
      }
      expect(g.checkFollow(), isNull);
      g.recordFollow();
      expect(g.checkFollow(), contains('tomorrow'));
      expect(() => SpamGuard.stopIf(g.checkFollow()), throwsA(isA<SpamLimitException>()));
      expect(g.checkPost(), isNull); // old accounts: no post limit
    });

    test('new account: 50 follows an hour, 10 posts a day', () {
      SpamGuard.debugCreated = _now.subtract(const Duration(hours: 1));
      for (var i = 0; i < 50; i++) {
        g.recordFollow();
      }
      expect(g.checkFollow(), contains('too fast'));
      for (var i = 0; i < 10; i++) {
        expect(g.checkPost(), isNull);
        g.recordPost();
      }
      expect(g.checkPost(), contains('10 posts'));
    });
  });
}
