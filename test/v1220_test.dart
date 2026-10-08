import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/app_notification.dart';
import 'package:instantgram/models/app_user.dart';
import 'package:instantgram/models/story.dart';
import 'package:instantgram/models/story_view.dart';
import 'package:instantgram/screens/settings/story_alerts_screen.dart';
import 'package:instantgram/screens/story/story_composer.dart';
import 'package:instantgram/services/push_service.dart';
import 'package:instantgram/services/story_views.dart';
import 'package:instantgram/widgets/story_peek.dart';
import 'package:instantgram/widgets/story_viewers_sheet.dart';

final _now = DateTime(2026, 10, 8, 21, 0);

StoryView _v(String uid, String name, int count, {int minsAgo = 5}) =>
    StoryView(
      uid: uid,
      username: name,
      first: _now.subtract(Duration(minutes: minsAgo + 60)),
      last: _now.subtract(Duration(minutes: minsAgo)),
      count: count,
    );

Story _story(String id) => Story(
  id: id,
  authorId: 'amy',
  username: 'amy',
  photoUrl: '',
  imageRef: '',
  createdAt: _now,
);

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  tearDown(() {
    final s = StoryViews.instance;
    s.recordBackend = null;
    s.listBackend = null;
    s.alertsBackend = null;
    s.saveAlertsBackend = null;
    s.forget();
    PushService.instance.sendBackend = null;
  });

  group('model', () {
    test('48 hours when chosen, else 24', () {
      expect(storyExpiry(_now, false), _now.add(const Duration(hours: 24)));
      expect(storyExpiry(_now, true), _now.add(const Duration(hours: 48)));
    });

    test('search, newest first, rewatches, time labels', () {
      final all = [
        _v('1', 'Zoe', 1, minsAgo: 30),
        _v('2', 'zack', 3),
        _v('3', 'bob', 1),
      ];
      expect(StoryView.filter(all, '@ZA').map((v) => v.uid), ['2']);
      expect(StoryView.filter(all, '  ').length, 3);
      expect(
        StoryView.sorted(all).first.uid,
        '2',
      ); // same time as bob, more views
      expect(StoryView.sorted(all).last.uid, '1');
      expect(rewatchLabel(1), '');
      expect(rewatchLabel(4), 'Watched 4 times');
      expect(viewTimeLabel(DateTime(2026, 10, 8, 9, 5), _now), '9:05 AM');
      expect(
        viewTimeLabel(DateTime(2026, 10, 7, 0, 30), _now),
        'Yesterday 12:30 AM',
      );
      expect(viewTimeLabel(DateTime(2026, 10, 5, 13, 0), _now), '5/10 1:00 PM');
    });

    test('a story view notification reads well', () {
      const n = AppNotification(
        id: 'n',
        type: 'story_view',
        actorId: 'a',
        actorName: 'aryan',
      );
      expect(n.verb, 'viewed your moment');
      expect(n.isStoryView, isTrue);
    });
  });

  group('counting views', () {
    test('one count per moment per visit; a new visit counts again', () async {
      final seen = <String>[];
      StoryViews.instance.recordBackend = (s) async => seen.add(s.id);
      final a = _story('a');
      StoryViews.instance.newVisit();
      await StoryViews.instance.record(a);
      await StoryViews.instance.record(a); // went back to it
      await StoryViews.instance.record(_story('b'));
      expect(seen, ['a', 'b']);
      StoryViews.instance
          .newVisit(); // opened the moments again later = rewatch
      await StoryViews.instance.record(a);
      expect(seen, ['a', 'b', 'a']);
    });

    test('a failing write never reaches the screen', () async {
      StoryViews.instance.recordBackend = (s) async => throw Exception('x');
      StoryViews.instance.newVisit();
      await StoryViews.instance.record(_story('a'));
    });

    test('the view alert push only carries the moment id', () async {
      final sent = <Map<String, dynamic>>[];
      PushService.instance.sendBackend = (b) async => sent.add(b);
      PushService.instance.storyView('s1');
      await Future<void>.delayed(Duration.zero);
      expect(sent, [
        {'kind': 'storyView', 'storyId': 's1'},
      ]);
    });
  });

  group('viewer list', () {
    Future<List<List<String>>> pumpSheet(
      WidgetTester t,
      List<String> alerts,
    ) async {
      final saved = <List<String>>[];
      StoryViews.instance.listBackend = (id) async => [
        _v('u1', 'zoe', 1, minsAgo: 40),
        _v('u2', 'zack', 3),
        _v('u3', 'bob', 1, minsAgo: 10),
      ];
      StoryViews.instance.alertsBackend = () async => alerts;
      StoryViews.instance.saveAlertsBackend = (l) async => saved.add(l);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StoryViewersSheet(storyId: 's1', now: _now),
          ),
        ),
      );
      await _settle(t);
      return saved;
    }

    testWidgets('count, rewatch badge, times', (t) async {
      await pumpSheet(t, []);
      expect(find.text('3 viewers'), findsOneWidget);
      expect(find.text('1 rewatched'), findsOneWidget);
      expect(find.byKey(const ValueKey('rewatch_u2')), findsOneWidget);
      expect(find.text('3×'), findsOneWidget);
      expect(find.byKey(const ValueKey('rewatch_u1')), findsNothing);
      expect(find.text('First 7:55 PM · last 8:55 PM'), findsOneWidget);
      expect(find.text('8:50 PM'), findsOneWidget); // bob, watched once
    });

    testWidgets('search narrows the list', (t) async {
      await pumpSheet(t, []);
      await t.enterText(find.byKey(const ValueKey('viewerSearch')), 'za');
      await _settle(t);
      expect(find.byKey(const ValueKey('viewer_u2')), findsOneWidget);
      expect(find.byKey(const ValueKey('viewer_u1')), findsNothing);
      expect(find.byKey(const ValueKey('viewer_u3')), findsNothing);
      await t.enterText(find.byKey(const ValueKey('viewerSearch')), 'nobody');
      await _settle(t);
      expect(find.text('Nobody with that name.'), findsOneWidget);
    });

    testWidgets('the bell turns alerts on and off for that person', (t) async {
      final saved = await pumpSheet(t, ['u3']);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('viewerAlert_u3')),
          matching: find.byIcon(Icons.notifications_active_rounded),
        ),
        findsOneWidget,
      );
      await t.tap(find.byKey(const ValueKey('viewerAlert_u2')));
      await _settle(t);
      expect(saved.last, ['u3', 'u2']);
      await t.tap(find.byKey(const ValueKey('viewerAlert_u3')));
      await _settle(t);
      expect(saved.last, ['u2']);
      await t.pump(const Duration(seconds: 4)); // toasts away
    });
  });

  group('peek', () {
    testWidgets('looks through the moments without counting; Watch opens', (
      t,
    ) async {
      var recorded = 0;
      StoryViews.instance.recordBackend = (s) async => recorded++;
      var opened = 0;
      final g = StoryGroup(
        authorId: 'amy',
        username: 'amy',
        photoUrl: '',
        stories: [_story('a'), _story('b')],
      );
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showStoryPeek(c, g, onOpen: () => opened++),
                  child: const Text('ring'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('ring'));
      await _settle(t);
      expect(find.byKey(const ValueKey('peekHint')), findsOneWidget);
      final peek = find.byKey(const ValueKey('storyPeek'));
      final box = t.getRect(peek);
      await t.tapAt(Offset(box.right - 20, box.center.dy)); // next
      await _settle(t);
      final second = find.byKey(const ValueKey('peekOpen'));
      expect(second, findsOneWidget);
      expect(recorded, 0);
      await t.tap(second);
      await _settle(t);
      expect(opened, 1);
      expect(find.byKey(const ValueKey('storyPeek')), findsNothing);
    });
  });

  group('settings', () {
    testWidgets('alert list: add by search, remove', (t) async {
      final saved = <List<String>>[];
      StoryViews.instance.alertsBackend = () async => ['u1'];
      StoryViews.instance.saveAlertsBackend = (l) async => saved.add(l);
      const zoe = AppUser(uid: 'u1', username: 'zoe');
      const zack = AppUser(uid: 'u2', username: 'zack');
      await t.pumpWidget(
        MaterialApp(
          home: StoryAlertsScreen(
            lookUp: (ids) async => [zoe],
            search: (q) async => [zoe, zack],
          ),
        ),
      );
      await _settle(t);
      expect(find.byKey(const ValueKey('alertPerson_u1')), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('alertSearch')), 'z');
      await t.pump(const Duration(milliseconds: 400));
      await _settle(t);
      await t.tap(find.byKey(const ValueKey('alertFound_u2')));
      await _settle(t);
      expect(saved.last, ['u1', 'u2']);
      expect(find.byKey(const ValueKey('alertPerson_u2')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('alertRemove_u1')));
      await _settle(t);
      expect(saved.last, ['u2']);
      expect(find.byKey(const ValueKey('alertPerson_u1')), findsNothing);
    });
  });

  group('composer', () {
    testWidgets('24h / 48h chip next to Share, fits a small phone', (t) async {
      final png = File('${Directory.systemTemp.path}/v1220_pixel.png')
        ..writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
          ),
        );
      await t.binding.setSurfaceSize(const Size(360, 740));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: StoryComposerScreen(image: png),
        ),
      );
      await t.pump();
      final chip = find.byKey(const ValueKey('story48h'));
      expect(chip, findsOneWidget);
      expect(find.text('24h'), findsOneWidget);
      await t.tap(chip);
      await t.pump();
      expect(find.text('48h'), findsOneWidget);
      expect(
        t.getRect(chip).right,
        lessThanOrEqualTo(
          t.getRect(find.byKey(const ValueKey('storyShare'))).left,
        ),
      );
    });
  });
}
