import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/app_user.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/screens/profile/analytics_screen.dart';
import 'package:instantgram/services/analytics_service.dart';

Post _post(String id, {bool clip = false, int likes = 0, int comments = 0}) =>
    Post(
      id: id,
      authorId: 'me',
      authorUsername: 'me',
      authorPhotoUrl: '',
      type: clip ? 'clip' : 'post',
      caption: 'caption of $id',
      createdAt: DateTime(2026, 10, 1),
      imageRef: 'https://cdn.test/$id.jpg',
      videoRef: clip ? 'https://cdn.test/$id.mp4' : '',
      likeCount: likes,
      commentCount: comments,
    );

AppUser _person(String uid, {String country = 'IN', String language = 'en'}) =>
    AppUser(
      uid: uid,
      username: uid,
      fullName: uid,
      bio: '',
      photoUrl: '',
      bannerUrl: '',
      links: const [],
      linkNames: const [],
      followersCount: 0,
      followingCount: 0,
      postsCount: 0,
      isPrivate: false,
      language: language,
      country: country,
    );

PostInsight _insight(
  Post p, {
  List<String> viewers = const [],
  int views = 0,
}) =>
    PostInsight(
      post: p,
      views: views == 0 ? viewers.length : views,
      reach: viewers.toSet().length,
      likes: p.likeCount,
      comments: p.commentCount,
      shares: 0,
      reposts: 0,
      viewerIds: viewers,
    );

/// Two posts: riya watched both, aman only one.
Insights _sample({int days = 7}) {
  final a = _post('a', clip: true, likes: 10, comments: 2);
  final b = _post('b', likes: 4, comments: 1);
  return Insights.build(
    days: days,
    posts: [
      _insight(a, viewers: const ['riya', 'aman'], views: 3),
      _insight(b, viewers: const ['riya']),
    ],
    people: {
      'riya': _person('riya', country: 'IN', language: 'hi'),
      'aman': _person('aman', country: 'US', language: 'en'),
    },
    followerIds: {'riya'},
    followerJoined: {'riya': DateTime(2026, 10, 5), 'old': DateTime(2026, 1, 1)},
    followersNow: 120,
    now: DateTime(2026, 10, 7, 12),
  );
}

void main() {
  setUp(() {
    AnalyticsService.instance.backend = null;
  });
  tearDown(() {
    AnalyticsService.instance.backend = null;
  });

  group('the numbers', () {
    test('a person who watched two posts is still one account reached', () {
      final d = _sample();
      expect(d.views, 4); // 3 + 1
      expect(d.reach, 2); // riya and aman
    });

    test('engagement is likes, comments, shares and reposts', () {
      final d = _sample();
      expect(d.likes, 14);
      expect(d.comments, 3);
      expect(d.engagement, 17);
      expect(d.engagementRate, closeTo(17 / 2, 0.001));
    });

    test('followers and everybody else are counted apart', () {
      final d = _sample();
      expect(d.followersReached, 1); // riya follows
      expect(d.nonFollowersReached, 1); // aman does not
      expect(d.followersGained, 1); // riya joined inside the 7 days
      expect(d.followersNow, 120);
      expect(d.reachRate, closeTo(2 / 120, 0.001));
    });

    test('the audience is grouped by country and language', () {
      final d = _sample();
      expect(d.countries['IN'], 1);
      expect(d.countries['US'], 1);
      expect(d.languages['hi'], 1);
      expect(d.languages['en'], 1);
    });

    test('the chart has one bar per day of the period', () {
      expect(_sample(days: 7).dailyViews.length, 7);
      expect(_sample(days: 30).dailyViews.length, 30);
    });

    test('nothing watched means nothing to show', () {
      final d = Insights.build(
        days: 7,
        posts: const [],
        people: const {},
        followerIds: const {},
        followerJoined: const {},
        followersNow: 0,
        now: DateTime(2026, 10, 7),
      );
      expect(d.isEmpty, isTrue);
      expect(d.engagementRate, 0);
      expect(d.avgViews, 0);
    });

    test('the best posts come first', () {
      final d = _sample();
      expect(d.topByReach.first.post.id, 'a');
      expect(d.topByEngagement.first.post.id, 'a');
      expect(d.topByViews.first.post.id, 'a');
    });
  });

  group('the screen', () {
    Future<void> open(
      WidgetTester tester, {
      Insights? data,
      Object? error,
    }) async {
      AnalyticsService.instance.backend = (days, uid) async {
        if (error != null) throw error;
        return data ?? _sample(days: days);
      };
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark, home: const AnalyticsScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('overview shows views, reach, engagement and new followers',
        (tester) async {
      await open(tester);
      expect(find.byKey(const ValueKey('statViews')), findsOneWidget);
      expect(find.byKey(const ValueKey('statReach')), findsOneWidget);
      expect(find.byKey(const ValueKey('statEngagement')), findsOneWidget);
      expect(find.byKey(const ValueKey('statFollowers')), findsOneWidget);
      expect(find.text('4'), findsWidgets); // views
      expect(find.text('2'), findsWidgets); // accounts reached
      expect(find.text('17'), findsWidgets); // engagement
      expect(find.text('+1'), findsWidgets); // new followers
      expect(find.text('Overview'), findsOneWidget);
    });

    testWidgets('reach, engagement and audience are three more tabs',
        (tester) async {
      await open(tester);
      await tester.tap(find.text('Reach'));
      await tester.pump();
      expect(find.byKey(const ValueKey('reachAccounts')), findsOneWidget);
      expect(find.text('Followers reached'), findsOneWidget);

      await tester.tap(find.text('Engagement'));
      await tester.pump();
      expect(find.byKey(const ValueKey('engLikes')), findsOneWidget);
      expect(find.text('Reposts'), findsWidgets); // the card and the bar

      await tester.tap(find.text('Audience'));
      await tester.pump();
      expect(find.byKey(const ValueKey('audFollowers')), findsOneWidget);
      expect(find.text('Where they are'), findsOneWidget);
      expect(find.text('IN'), findsWidgets);
    });

    testWidgets('the range can be changed to 30 or 90 days', (tester) async {
      final asked = <int>[];
      AnalyticsService.instance.backend = (days, uid) async {
        asked.add(days);
        return _sample(days: days);
      };
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark, home: const AnalyticsScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(asked, [7]);

      await tester.tap(find.text('30 days'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(asked, [7, 30]);
      // the period is written on the cards
      expect(find.textContaining('in the last 30 days'), findsWidgets);

      await tester.tap(find.text('90 days'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(asked, [7, 30, 90]);
    });

    testWidgets('with nothing watched yet it says so', (tester) async {
      AnalyticsService.instance.backend = (days, uid) async =>
          Insights.build(
            days: days,
            posts: const [],
            people: const {},
            followerIds: const {},
            followerJoined: const {},
            followersNow: 0,
          );
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark, home: const AnalyticsScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('No numbers yet'), findsOneWidget);
    });

    testWidgets('a failed read can be tried again', (tester) async {
      var calls = 0;
      AnalyticsService.instance.backend = (days, uid) async {
        calls++;
        if (calls == 1) throw StateError('permission denied');
        return _sample(days: days);
      };
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark, home: const AnalyticsScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(calls, 1);
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(calls, 2);
      expect(find.byKey(const ValueKey('statViews')), findsOneWidget);
    });
  });
}
