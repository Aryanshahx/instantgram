import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/post_authors.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/services/app_prefs.dart';
import 'package:instantgram/services/feed_ranker.dart';
import 'package:instantgram/services/feed_signals.dart';
import 'package:instantgram/services/post_pager.dart';
import 'package:instantgram/services/safety_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

final DateTime _now = DateTime(2026, 10, 10, 12);

Post _p(
  String id, {
  String author = 'other',
  String type = 'image',
  int likes = 0,
  int comments = 0,
  double hours = 1,
  int seconds = 10,
}) => Post(
  id: id,
  authorId: author,
  authorUsername: author,
  authorPhotoUrl: '',
  type: type,
  caption: '',
  createdAt: _now.subtract(Duration(minutes: (hours * 60).round())),
  likeCount: likes,
  commentCount: comments,
  videoDuration: seconds,
  videoRef: type == 'video' ? 'm:video/u/aaaaaaaaaaaaaaaa.mp4' : '',
  imageRef: 'm:image/u/aaaaaaaaaaaaaaaa.jpg',
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppPrefs.instance.init();
    SafetyService.instance.me = 'me';
    SafetyService.instance.following = {'friend', 'pal'};
    Closeness.instance.now = () => _now;
    WatchLog.instance.now = () => _now;
    FeedRanker.instance.now = () => _now;
    Closeness.instance.clear();
    WatchLog.instance.clear();
  });

  tearDown(() {
    SafetyService.instance.following = {};
    debugTrendingSource = null;
  });

  group('closeness', () {
    test(
      'likes, comments and messages add points that fade over two weeks',
      () {
        final c = Closeness.instance;
        c.bump('friend', Signal.like);
        c.bump('friend', Signal.comment);
        expect(c.scoreOf('friend'), 8);
        c.now = () => _now.add(const Duration(days: 14));
        expect(c.scoreOf('friend'), closeTo(4, 0.01));
        c.now = () => _now.add(const Duration(days: 28));
        expect(c.scoreOf('friend'), closeTo(2, 0.01));
        expect(c.scoreOf('nobody'), 0);
      },
    );

    test('never negative, never about myself', () {
      final c = Closeness.instance;
      c.bump('x', Signal.skipped);
      expect(c.scoreOf('x'), 0);
      c.bump('me', Signal.like);
      expect(c.scoreOf('me'), 0);
    });

    test('kept on the phone per account, at most 300 accounts', () {
      final c = Closeness.instance;
      c.bump('friend', Signal.share);
      c.reload();
      expect(c.scoreOf('friend'), 4);
      SafetyService.instance.me = 'other-me';
      expect(c.scoreOf('friend'), 0);
      SafetyService.instance.me = 'me';
      expect(c.scoreOf('friend'), 4);
      for (var i = 0; i < 320; i++) {
        c.bump('u$i', Signal.profileVisit);
      }
      c.reload();
      expect(c.scoreOf('friend'), 4, reason: 'the closest stay');
      final kept = [for (var i = 0; i < 320; i++) c.scoreOf('u$i') > 0];
      expect(kept.where((k) => k).length, lessThanOrEqualTo(299));
    });

    test('a like on a post counts for its author', () {
      rememberAuthor('post9', 'pal');
      Closeness.instance.bumpPost('post9', Signal.save);
      expect(Closeness.instance.scoreOf('pal'), 3);
      Closeness.instance.bumpPost('unknown', Signal.save); // no crash
    });

    test('Following asks for the 30 closest people', () {
      for (var i = 0; i < 40; i++) {
        Closeness.instance.bump(
          'f$i',
          i == 35 ? Signal.comment : Signal.message,
        );
      }
      final ids = Closeness.instance.closest([
        for (var i = 0; i < 40; i++) 'f$i',
        'never',
      ]);
      expect(ids.length, 30);
      expect(ids.first, 'f35');
      expect(ids, isNot(contains('never')));
    });
  });

  group('watch log', () {
    test(
      'watching to the end brings the author closer, a quick skip pushes away',
      () {
        final w = WatchLog.instance;
        w.watched(
          'c1',
          'friend',
          const Duration(seconds: 9),
          const Duration(seconds: 10),
        );
        expect(w.percent('c1'), 90);
        expect(Closeness.instance.scoreOf('friend'), 1);
        Closeness.instance.bump('pal', Signal.like);
        w.watched(
          'c2',
          'pal',
          const Duration(milliseconds: 800),
          const Duration(seconds: 10),
        );
        expect(Closeness.instance.scoreOf('pal'), 2.5);
        w.watched(
          'c3',
          'pal',
          const Duration(seconds: 4),
          const Duration(seconds: 10),
        );
        expect(
          Closeness.instance.scoreOf('pal'),
          2.5,
          reason: 'in between: no change',
        );
      },
    );

    test('scrolled-past posts are remembered, oldest forgotten after 600', () {
      final w = WatchLog.instance;
      w.markSeen('a');
      expect(w.seen('a'), isTrue);
      expect(w.percent('a'), 0);
      expect(w.percent('b'), isNull);
      for (var i = 0; i < 700; i++) {
        WatchLog.instance.now = () => _now.add(Duration(seconds: i));
        w.markSeen('s$i');
      }
      w.flush();
      w.reload();
      expect(w.seen('s699'), isTrue);
      expect(w.seen('a'), isFalse);
    });
  });

  group('ranking', () {
    test('close friends and fresh posts come first, seen posts sink', () {
      final r = FeedRanker.instance;
      Closeness.instance.bump('friend', Signal.comment);
      final fresh = _p('fresh', author: 'friend', hours: 1);
      final old = _p('old', author: 'friend', likes: 2, hours: 30);
      final stranger = _p('stranger', likes: 1, hours: 1);
      expect(r.score(fresh), greaterThan(r.score(old)));
      expect(r.score(fresh), greaterThan(r.score(stranger)));
      final before = r.score(fresh);
      WatchLog.instance.markSeen('fresh');
      expect(r.score(fresh), closeTo(before * 0.25, 1e-9));
    });

    test('popular posts from strangers can still beat quiet ones', () {
      final r = FeedRanker.instance;
      final quiet = _p('q', author: 'pal', hours: 5);
      final hit = _p('h', likes: 40, comments: 10, hours: 5);
      expect(r.score(hit), greaterThan(r.score(quiet)));
    });

    test('Home: every 6th post is from somebody I do not follow', () {
      final page = [
        for (var i = 0; i < 10; i++)
          _p('f$i', author: 'friend', hours: i + 1.0),
        for (var i = 0; i < 4; i++) _p('o$i', author: 'o$i', hours: 1),
        _p('mine', author: 'me', hours: 0.5),
      ];
      final out = FeedRanker.instance.arrangeHome(page);
      expect(out.length, page.length);
      expect(out.map((p) => p.id).toSet().length, page.length);
      expect(out[5].authorId, startsWith('o'));
      expect(out[11].authorId, startsWith('o'));
      for (final i in [0, 1, 2, 3, 4, 6, 7, 8, 9, 10]) {
        expect(out[i].authorId, anyOf('friend', 'me'), reason: 'slot $i');
      }
      expect(FeedRanker.instance.reasonFor('mine'), FeedReason.yours);
      expect(FeedRanker.instance.reasonFor('o0'), FeedReason.discover);
    });

    test('Home with nobody followed is just the best first', () {
      SafetyService.instance.following = {};
      final out = FeedRanker.instance.arrangeHome([
        _p('a', author: 'x', likes: 1),
        _p('b', author: 'y', likes: 9),
      ]);
      expect(out.map((p) => p.id), ['b', 'a']);
    });

    test('Clips: 7 followed, 2 trending, 1 new in every 10', () {
      final page = [
        for (var i = 0; i < 7; i++)
          _p('f$i', author: 'friend', type: 'video', hours: i + 1.0),
        _p('t0', author: 't', type: 'video', likes: 99),
        _p('t1', author: 't', type: 'video', likes: 50),
        _p('n0', author: 'n', type: 'video'),
      ];
      final out = FeedRanker.instance.arrangeClips(
        page,
        trending: {'t0', 't1'},
      );
      expect(out.map((p) => p.id[0]).join(), 'fftffnftff');
      expect(FeedRanker.instance.reasonFor('t0'), FeedReason.trending);
    });

    test('Clips fall back to what there is', () {
      final out = FeedRanker.instance.arrangeClips([
        _p('n0', author: 'a', type: 'video', hours: 2),
        _p('n1', author: 'b', type: 'video', hours: 1),
      ]);
      expect(out.map((p) => p.id), ['n1', 'n0']);
    });

    test('accounts I watch a lot count as followed in Clips', () {
      for (var i = 0; i < 3; i++) {
        Closeness.instance.bump('fan', Signal.watchedFully);
      }
      final out = FeedRanker.instance.arrangeClips([
        _p('x', author: 'fan', type: 'video'),
        _p('n', author: 'z', type: 'video'),
      ]);
      expect(out.first.id, 'x');
    });
  });

  group('pager', () {
    test(
      'trending seed joins the first page once, no repeats across pages',
      () async {
        final pages = [
          [_p('a'), _p('b'), _p('t')],
          [_p('b'), _p('c'), _p('d')],
          [_p('e')],
        ];
        var seeded = 0;
        Set<String>? got;
        final pager = PostPager(
          () => throw StateError('no firestore'),
          pageSize: 3,
          feed: true,
          fetchPage: (n) async => pages[n],
          seed: () async {
            seeded++;
            return [_p('t', likes: 5)];
          },
          arrange: (page, s) {
            got ??= s;
            return page.reversed.toList();
          },
        );
        await pager.loadMore();
        expect(pager.posts.map((p) => p.id), ['b', 'a', 't']);
        expect(got, {'t'});
        await pager.loadMore();
        await pager.loadMore();
        expect(pager.posts.map((p) => p.id), ['b', 'a', 't', 'd', 'c', 'e']);
        expect(pager.hasMore, isFalse);
        expect(seeded, 1);
        await pager.refresh();
        expect(seeded, 2);
        expect(pager.posts.length, 3);
        pager.dispose();
      },
    );

    test('a failing trending list does not stop the feed', () async {
      final pager = PostPager(
        () => throw StateError('no firestore'),
        pageSize: 5,
        fetchPage: (n) async => [_p('a')],
        seed: () async => throw StateError('offline'),
      );
      await pager.loadMore();
      expect(pager.error, isNull);
      expect(pager.posts.map((p) => p.id), ['a']);
      pager.dispose();
    });

    test('trending posts hook', () async {
      debugTrendingSource = (clips) async => [_p(clips ? 'clip' : 'post')];
      expect(
        (await TrendingService.instance.load(clips: true)).single.id,
        'clip',
      );
    });
  });

  test('Home remembers For you / Following', () {
    expect(AppPrefs.instance.feedMode, '');
    AppPrefs.instance.feedMode = 'following';
    expect(AppPrefs.instance.feedMode, 'following');
  });
}
