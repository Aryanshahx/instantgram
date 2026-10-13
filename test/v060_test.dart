import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/services/media_prefetch.dart';
import 'package:instantgram/core/services/media_service.dart';
import 'package:instantgram/core/services/music_player.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/core/utils/merge_streams.dart';
import 'package:instantgram/features/auth/presentation/login_screen.dart';
import 'package:instantgram/features/chats/data/chat_repository.dart';
import 'package:instantgram/features/chats/presentation/chat_detail_screen.dart';
import 'package:instantgram/features/chats/presentation/share_sheet.dart';
import 'package:instantgram/features/dashboard/presentation/dashboard_screen.dart';
import 'package:instantgram/features/feed/presentation/widgets/story_bar.dart';
import 'package:instantgram/features/insights/post_insights.dart';
import 'package:instantgram/features/post/data/post_repository.dart';
import 'package:instantgram/features/profile/data/famous_index.dart';
import 'package:instantgram/features/search/presentation/explore_screen.dart';
import 'package:instantgram/features/stories/data/moments_index.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/models/user_profile.dart';
import 'package:instantgram/shared/widgets/avatar.dart';
import 'package:instantgram/shared/widgets/ig_text_field.dart';
import 'package:instantgram/shared/widgets/media_view.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';

Widget _app(Widget child) => MaterialApp(theme: AppTheme.dark, home: child);

Post _post(String id, Map<String, dynamic> m) => Post.fromMap(id, {
  'authorId': 'a1',
  'authorUsername': 'riya',
  'type': 'photo',
  'mediaUrl': 'https://x/$id.jpg',
  'createdAt': DateTime(2026, 10, 1),
  ...m,
});

Story _story(String id, String author) => Story.fromMap(id, {
  'authorId': author,
  'authorUsername': author,
  'authorPhotoUrl': '',
  'mediaUrl': 'https://x/$id.jpg',
  'type': 'photo',
  'createdAt': DateTime.now().subtract(const Duration(hours: 1)),
  'expiresAt': DateTime.now().add(const Duration(hours: 23)),
});

UserProfile _me() => UserProfile.fromMap('me', {
  'uid': 'me',
  'username': 'aryan',
  'name': 'Aryan',
  'followersCount': 12,
  'followingCount': 3,
});

Future<void> _frames(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MusicPlayer.disabled = true;
    kDisableVideoPlayback = true;
    NetImage.disableCache = true;
    MediaPrefetch.disabled = true;
    VideoPool.disabled = true;
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  // ------------------------------------------------------------ feed
  test('feed = me + following + famous, no duplicates', () {
    expect(feedAuthors('me', ['a', 'b'], ['b', 'c']), ['me', 'a', 'b', 'c']);
    expect(feedAuthors('me', ['me', 'a'], const []), ['me', 'a']);
    expect(feedAuthors('me', ['a', 'b', 'c'], ['d'], max: 2), ['me', 'a']);
    expect(FamousIndex.minFollowers, 10000);
  });

  test('merged feed: newest first, no duplicates, limited', () {
    final a = _post('a', {'createdAt': DateTime(2026, 10, 1)});
    final b = _post('b', {'createdAt': DateTime(2026, 10, 3)});
    final c = _post('c', {'createdAt': DateTime(2026, 10, 2)});
    final merged = mergeNewest([
      [a, b],
      [b, c],
    ]);
    expect(merged.map((p) => p.id), ['b', 'c', 'a']);
    expect(
      mergeNewest([
        [a, b, c],
      ], max: 2).map((p) => p.id),
      ['b', 'c'],
    );
  });

  test('combine waits for every part, then follows changes', () async {
    final s1 = StreamController<List<int>>();
    final s2 = StreamController<List<int>>();
    final out = <List<int>>[];
    final sub = combineLatestList<List<int>, List<int>>([
      s1.stream,
      s2.stream,
    ], (all) => all.expand((e) => e).toList()).listen(out.add);
    s1.add([1]);
    await Future<void>.delayed(Duration.zero);
    expect(out, isEmpty); // part 2 not here yet
    s2.add([2]);
    await Future<void>.delayed(Duration.zero);
    expect(out.last, [1, 2]);
    s1.add([3]);
    await Future<void>.delayed(Duration.zero);
    expect(out.last, [3, 2]);
    // an error in one part does not break the feed
    final s3 = StreamController<List<int>>();
    final s4 = StreamController<List<int>>();
    final out2 = <List<int>>[];
    final sub2 = combineLatestList<List<int>, List<int>>([
      s3.stream,
      s4.stream,
    ], (all) => all.expand((e) => e).toList()).listen(out2.add);
    s3.add([7]);
    s4.addError(StateError('no'));
    await Future<void>.delayed(Duration.zero);
    expect(out2.last, [7]);
    await sub.cancel();
    await sub2.cancel();
  });

  // ------------------------------------------------------------ picker
  test('video detection by name and by first bytes', () {
    expect(isVideoPath('/a/b.MP4'), isTrue);
    List<int> ftyp(String brand) => [
      0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, ...brand.codeUnits, 0, 0, 0, 0, //
    ];
    expect(isVideoHeader(ftyp('isom')), isTrue);
    expect(isVideoHeader(ftyp('qt  ')), isTrue);
    expect(isVideoHeader(ftyp('3gp4')), isTrue);
    expect(isVideoHeader(ftyp('heic')), isFalse); // iPhone-style photo
    expect(isVideoHeader(ftyp('avif')), isFalse);
    expect(isVideoHeader([0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0]), isTrue);
    expect(isVideoHeader([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]), isFalse);

    final dir = Directory.systemTemp.createTempSync('ig');
    addTearDown(() => dir.deleteSync(recursive: true));
    final noExtVideo = File('${dir.path}/1000012345')
      ..writeAsBytesSync(ftyp('mp42'));
    final noExtPhoto = File('${dir.path}/1000012346')
      ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 5, 6, 7, 8]);
    final jpg = File('${dir.path}/x.jpg')..writeAsBytesSync(ftyp('mp42'));
    expect(isVideoFile(noExtVideo), isTrue);
    expect(isVideoFile(noExtPhoto), isFalse);
    expect(isVideoFile(jpg), isFalse); // name says photo
  });

  // ------------------------------------------------------------ moments
  testWidgets('moment ring: no glow, seen ring stays visible', (tester) async {
    await tester.pumpWidget(
      _app(
        const Column(
          children: [
            MomentRing(key: ValueKey('new'), child: SizedBox(width: 40)),
            MomentRing(
              key: ValueKey('seen'),
              seen: true,
              child: SizedBox(width: 40),
            ),
          ],
        ),
      ),
    );
    BoxDecoration deco(String k) =>
        tester
                .widget<Container>(
                  find
                      .descendant(
                        of: find.byKey(ValueKey(k)),
                        matching: find.byType(Container),
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;
    expect(deco('new').boxShadow, isNull);
    expect(deco('new').gradient, isNotNull);
    expect(deco('seen').boxShadow, isNull);
    expect(deco('seen').color, kSeenRingColor);
    // clearly lighter than the dark background
    expect(kSeenRingColor.computeLuminance(), greaterThan(0.2));
  });

  testWidgets('moments row: only me, people I follow and famous', (
    tester,
  ) async {
    MomentsIndex.instance.debugSet([
      StoryGroup('friend', [_story('s1', 'friend')]),
      StoryGroup('stranger', [_story('s2', 'stranger')]),
      StoryGroup('star', [_story('s3', 'star')]),
    ]);
    addTearDown(() => MomentsIndex.instance.debugSet(const []));
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: StoryBar(
            me: _me(),
            myUid: 'me',
            allowed: const {'me', 'friend', 'star'},
            onAddStory: () {},
          ),
        ),
      ),
    );
    await _frames(tester, 3);
    expect(find.text('friend'), findsOneWidget);
    expect(find.text('star'), findsOneWidget);
    expect(find.text('stranger'), findsNothing);
    expect(find.text('You'), findsOneWidget);
  });

  // ------------------------------------------------------------ explore
  test('explore autoplay: most visible tiles, max players', () async {
    final a = ExploreAutoplay(maxPlayers: 2, minVisible: 0.5);
    var changes = 0;
    a.addListener(() => changes++);
    a.report('p1', 1.0);
    a.report('p2', 0.9);
    a.report('p3', 0.7);
    a.report('p4', 0.3); // too little visible
    expect(a.active, {'p1', 'p2'});
    a.report('p1', 0);
    expect(a.active, {'p2', 'p3'});
    a.forget('p2');
    await Future<void>.delayed(Duration.zero);
    expect(a.active, {'p3'});
    expect(changes, greaterThan(0));
    a.dispose();
    a.report('p9', 1); // after dispose: ignored, no crash
  });

  testWidgets('explore tile: views, no play icon, no likes', (tester) async {
    final auto = ExploreAutoplay();
    addTearDown(auto.dispose);
    final clip = _post('c1', {
      'type': 'clip',
      'uniqueViews': 1500,
      'likesCount': 77,
      'media': [
        {
          'type': 'video',
          'url': 'https://x/c1.mp4',
          'thumbUrl': 'https://x/c1.jpg',
        },
      ],
    });
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: SizedBox(
            width: 200,
            child: ExploreTile(post: clip, autoplay: auto, onTap: () {}),
          ),
        ),
      ),
    );
    await _frames(tester, 3);
    expect(find.byKey(const ValueKey('explore-views')), findsOneWidget);
    expect(find.text('1.5K'), findsOneWidget);
    expect(find.text('77'), findsNothing);
    expect(find.byIcon(Icons.play_circle_fill), findsNothing);
    expect(find.byIcon(Icons.favorite), findsNothing);
    expect(auto.isActive('c1'), isTrue); // visible -> plays (muted)
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
  });

  // ------------------------------------------------------------ share
  testWidgets('share sheet: people, search, send, copy link', (tester) async {
    final sent = <String>[];
    final post = _post('p1', {'caption': 'hello'});
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: ShareSheet(
            post: post,
            loadTargets: () async => const [
              ChatPerson(
                uid: 'u1',
                username: 'neha',
                photoUrl: '',
                recent: true,
              ),
              ChatPerson(
                uid: 'u2',
                username: 'rahul',
                photoUrl: '',
                name: 'Rahul K',
              ),
            ],
            send: (to, p) async => sent.add('${to.uid}:${p.id}'),
          ),
        ),
      ),
    );
    await _frames(tester, 3);
    expect(find.text('neha'), findsOneWidget);
    expect(find.text('Recent chat'), findsOneWidget);
    expect(find.text('rahul'), findsOneWidget);
    expect(find.byKey(const ValueKey('share-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('share-more')), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('share-search')), 'rah');
    await tester.pump();
    expect(find.text('neha'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('share-send-u2')));
    await _frames(tester, 2);
    expect(sent, ['u2:p1']);
    expect(find.text('Sent'), findsOneWidget);
    // a second tap does not send again
    await tester.tap(find.byKey(const ValueKey('share-send-u2')));
    await tester.pump();
    expect(sent.length, 1);
  });

  testWidgets('shared post shows as a card in the chat', (tester) async {
    final m = Message(
      id: 'm1',
      senderId: 'u1',
      text: 'Shared a clip by @riya',
      createdAt: DateTime(2026, 10, 13),
      postId: 'p9',
      postType: Post.clip,
      postThumb: 'https://x/t.jpg',
      postAuthor: 'riya',
      postCaption: 'sunset',
    );
    expect(m.isSharedPost, isTrue);
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Center(child: SharedPostCard(message: m, mine: false)),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('@riya'), findsOneWidget);
    expect(find.text('sunset'), findsOneWidget);
    expect(find.byKey(const ValueKey('shared-post-p9')), findsOneWidget);
  });

  // ------------------------------------------------------------ dashboard
  test('account analytics add up many posts', () {
    final photo = _post('p1', {
      'uniqueViews': 2,
      'likesCount': 3,
      'commentsCount': 1,
      'createdAt': DateTime(2026, 10, 1),
    });
    final clip = _post('p2', {
      'type': 'clip',
      'uniqueViews': 1,
      'likesCount': 1,
      'sharesCount': 2,
      'createdAt': DateTime(2026, 10, 5),
      'media': [
        {'type': 'video', 'url': 'https://x/v.mp4'},
      ],
    });
    final d = PostInsights.fromMany(
      [photo, clip],
      [
        [
          {'_id': 'u1', 'follower': true, 'country': 'IN', 'count': 2},
          {'_id': 'u2', 'follower': false, 'country': 'US', 'count': 1},
        ],
        [
          {
            '_id': 'u1',
            'follower': true,
            'country': 'IN',
            'count': 1,
            'watchMs': 3000,
            'completed': true,
          },
        ],
      ],
      now: DateTime(2026, 10, 13),
    );
    expect(d.isAccount, isTrue);
    expect(d.postCount, 2);
    expect(d.reach, 2); // u1 + u2 (u1 counted once)
    expect(d.views, 4); // 3 + 1
    expect(d.likes, 4);
    expect(d.interactions, 4 + 1 + 2);
    expect(d.detailed, 3);
    expect(d.followerViews, 2);
    expect(d.countries.first, ('IN', 2));
    expect(d.hasVideo, isTrue);
    expect(d.completionRate, 1.0); // only video posts count
    expect(d.avgWatchMs, 3000);
    expect(d.hourly, isFalse);
    expect(d.interactionsPerPost, 3.5);
  });

  testWidgets('dashboard shows overview, engagement and audience', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final p = _post('p1', {'uniqueViews': 2, 'likesCount': 5});
    final docs = [
      {'_id': 'u1', 'follower': true, 'country': 'IN', 'ageGroup': '18-24'},
      {'_id': 'u2', 'follower': false, 'country': 'IN', 'ageGroup': '25-34'},
    ];
    await tester.pumpWidget(
      _app(
        DashboardScreen(
          loader: () async =>
              DashboardData(_me(), [p], PostInsights.fromMany([p], [docs])),
        ),
      ),
    );
    await _frames(tester);
    expect(find.byKey(const ValueKey('dash-account')), findsOneWidget);
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Engagement'), findsWidgets);
    expect(find.text('Audience'), findsOneWidget);
    expect(find.text('Accounts reached'), findsOneWidget);
    expect(find.text('Posts counted'), findsOneWidget);
    expect(find.textContaining('India'), findsOneWidget);
    expect(find.text('Top posts'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ------------------------------------------------------------ auth size
  testWidgets('login screen is compact', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(const LoginScreen()));
    await tester.pump();
    for (final f in tester.widgetList<IgTextField>(find.byType(IgTextField))) {
      expect(f.height, lessThanOrEqualTo(48));
    }
    final big = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => (t.style?.fontSize ?? 0) > 34);
    expect(big, isEmpty);
    expect(tester.takeException(), isNull);
  });

  // ------------------------------------------------------------ prefetch
  test('prefetch does nothing when switched off', () {
    final p = _post('p1', {
      'media': [
        {'type': 'video', 'url': 'https://x/v.mp4'},
      ],
    });
    MediaPrefetch.instance.ahead([p, p, p], 0);
    VideoPool.instance.prefetch('https://x/v.mp4');
    expect(VideoPool.instance.size, 0);
    expect(VideoPool.instance.take('https://x/v.mp4'), isNull);
  });
}
