import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/chat.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/screens/post/create_post_screen.dart';
import 'package:instantgram/widgets/app_nav_bar.dart';
import 'package:instantgram/widgets/inline_video.dart';
import 'package:instantgram/widgets/message_bubble.dart';

// a valid 1x1 picture
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Post _clip() => Post(
  id: 'p1',
  authorId: 'u',
  authorUsername: 'user',
  authorPhotoUrl: '',
  type: 'video',
  caption: 'c',
  createdAt: DateTime(2026, 1, 1),
  videoRef: 'https://cdn.test/clip.mp4',
);

void main() {
  navTests();
  group('chat ids and threads', () {
    test('two people always get the same chat id', () {
      expect(chatIdFor('b', 'a'), 'a_b');
      expect(chatIdFor('a', 'b'), 'a_b');
      expect(chatMembers('z', 'm'), ['m', 'z']);
    });

    test('unread: only their last message that I have not opened', () {
      final t0 = DateTime(2026, 1, 1, 10);
      final t1 = DateTime(2026, 1, 1, 11);
      ChatThread th({String sender = 'bob', Map<String, DateTime>? seen}) =>
          ChatThread(
            id: 'alice_bob',
            members: const ['alice', 'bob'],
            lastText: 'hi',
            lastAt: t1,
            lastSender: sender,
            seen: seen ?? const {},
          );
      expect(th().isUnread('alice'), isTrue);
      expect(th(seen: {'alice': t0}).isUnread('alice'), isTrue);
      expect(th(seen: {'alice': t1}).isUnread('alice'), isFalse);
      expect(th(sender: 'alice').isUnread('alice'), isFalse);
      expect(th().other('alice'), 'bob');
      expect(th().other('bob'), 'alice');
    });

    test('a chat without messages is not shown', () {
      const t = ChatThread(id: 'a_b', members: ['a', 'b']);
      expect(t.hasMessages, isFalse);
      expect(t.isUnread('a'), isFalse);
    });
  });

  group('message bubble', () {
    testWidgets('mine on the right in volt green, theirs on the left', (
      t,
    ) async {
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: Column(
              children: [
                MessageBubble(text: 'from me', mine: true, time: '10:00'),
                MessageBubble(text: 'from you', mine: false, time: '10:01'),
                MessageBubble(
                  text: 'wait',
                  mine: true,
                  time: '10:02',
                  pending: true,
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('from me'), findsOneWidget);
      final mine = t.getTopRight(find.text('from me')).dx;
      final theirs = t.getTopLeft(find.text('from you')).dx;
      expect(mine, greaterThan(theirs + 100));
      expect(find.text('Sending...'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    test('times: today, this week, older', () {
      final now = DateTime(2026, 10, 4, 15, 0);
      expect(chatTime(DateTime(2026, 10, 4, 9, 5), now: now), '09:05');
      expect(chatTime(DateTime(2026, 10, 2, 9, 5), now: now), 'Fri 09:05');
      expect(chatTime(DateTime(2026, 8, 12, 9, 5), now: now), '12 Aug');
    });
  });

  group('clips in the feed only play on screen', () {
    testWidgets('a hidden tab (TickerMode off) never has a playing clip', (
      t,
    ) async {
      final hub = InlineVideoHub.instance;
      Widget app(bool visible) => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 100),
              child: TickerMode(
                enabled: visible,
                child: SizedBox(
                  width: 300,
                  height: 400,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [InlineVideoLayer(post: _clip())],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await t.pumpWidget(app(true));
      await t.pump();
      expect(hub.active.value, 'p1'); // visible: it is the one to play

      await t.pumpWidget(app(false)); // user switches to another tab
      await t.pump();
      expect(hub.active.value, isNull);

      await t.pumpWidget(app(true)); // comes back
      await t.pump();
      expect(hub.active.value, 'p1');

      await t.pumpWidget(
        const SizedBox(),
      ); // leaves (also stops the start timer)
      await t.pump();
      expect(hub.active.value, isNull);
    });
  });

  group('Create: audio in the preview, title required', () {
    late File photo;

    setUp(() {
      photo = File('${Directory.systemTemp.path}/ig_test_photo.png')
        ..writeAsBytesSync(_png);
    });

    Future<void> open(WidgetTester t) async {
      t.view.physicalSize = const Size(1080, 2000);
      t.view.devicePixelRatio = 2.5;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: CreatePostScreen(debugImage: photo),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
    }

    testWidgets(
      'Post: the music button is under the preview, no volume slider',
      (t) async {
        await open(t);
        expect(find.byKey(const ValueKey('audioBar')), findsOneWidget);
        expect(find.byKey(const ValueKey('editButton')), findsOneWidget);
        expect(find.text('Music'), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('audioBar')));
        await t.pump(const Duration(milliseconds: 500));
        expect(find.byType(Slider), findsNothing); // no custom volume range
        expect(find.text('Length'), findsNothing); // photo clips are always 5 s
        expect(t.takeException(), isNull);
      },
    );

    testWidgets('Clips: a photo needs music first, no length choice', (
      t,
    ) async {
      await open(t);
      await t.tap(find.byKey(const ValueKey('mode1')));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Add music (needed)'), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
      await t.tap(find.byKey(const ValueKey('nextButton')));
      await t.pump(const Duration(milliseconds: 600));
      // the toast tells why, and the music picker opens instead of the details
      expect(
        find.text('Add music to make a clip from a photo.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('captionField')), findsNothing);
      expect(find.text('Length'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('Share stays off until there is a caption', (t) async {
      await open(t);
      await t.tap(find.byKey(const ValueKey('nextButton')));
      await t.pump(const Duration(milliseconds: 400));
      FilledButton share() =>
          t.widget<FilledButton>(find.byKey(const ValueKey('shareButton')));
      expect(find.text('A caption is required'), findsOneWidget);
      expect(share().onPressed, isNull);
      await t.enterText(find.byKey(const ValueKey('captionField')), '   ');
      await t.pump();
      expect(share().onPressed, isNull);
      await t.enterText(find.byKey(const ValueKey('captionField')), 'Sunset');
      await t.pump();
      expect(share().onPressed, isNotNull);
      expect(t.takeException(), isNull);
    });

    testWidgets('Details: big cover, options, Share button always visible', (
      t,
    ) async {
      await open(t);
      await t.tap(find.byKey(const ValueKey('nextButton')));
      await t.pump(const Duration(milliseconds: 400));
      final cover = t.getSize(find.byKey(const ValueKey('detailsThumb')));
      expect(cover.height, greaterThanOrEqualTo(2000 / 2.5 / 2 - 1));
      expect(find.byKey(const ValueKey('audienceRow')), findsOneWidget);
      expect(find.byKey(const ValueKey('storyRow')), findsOneWidget);
      expect(find.byKey(const ValueKey('shareButton')), findsOneWidget);
      // the three count switches are inside Advanced settings
      await t.scrollUntilVisible(
        find.byKey(const ValueKey('advancedRow')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.byKey(const ValueKey('advancedRow')));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('hideLikesRow')), findsOneWidget);
      await t.scrollUntilVisible(
        find.byKey(const ValueKey('audienceRow')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.byKey(const ValueKey('audienceRow')));
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.byKey(const ValueKey('audience_followers')));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Followers'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('carousel: several photos, counter, remove one', (t) async {
      t.view.physicalSize = const Size(1080, 2000);
      t.view.devicePixelRatio = 2.5;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: CreatePostScreen(debugImages: [photo, photo, photo]),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('mediaStrip')), findsOneWidget);
      expect(find.byKey(const ValueKey('tile2')), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('tile1')));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('2/3'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('remove1')));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('tile2')), findsNothing);
      expect(find.text('2/2'), findsOneWidget); // the next photo moved up
      await t.tap(find.byKey(const ValueKey('remove0')));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('tile1')), findsNothing);
      expect(find.byKey(const ValueKey('tile0')), findsOneWidget);
      expect(find.text('1/1'), findsNothing); // no counter for one photo
      expect(t.takeException(), isNull);
    });
  });
}

void navTests() {
  group('bottom bar', () {
    for (final w in const [320.0, 360.0, 411.0, 800.0]) {
      for (var sel = 0; sel < 5; sel++) {
        testWidgets('fits at ${w.toInt()} dp with tab $sel selected', (
          t,
        ) async {
          t.view.physicalSize = Size(w * 2, 1600);
          t.view.devicePixelRatio = 2;
          addTearDown(t.view.reset);
          var picked = -1;
          await t.pumpWidget(
            MaterialApp(
              theme: AppTheme.dark,
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: AppNavBar(
                        index: sel,
                        chatDot: true,
                        onSelect: (i) => picked = i,
                        onCreate: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await t.pump(const Duration(milliseconds: 400));
          expect(t.takeException(), isNull);
          // thin: the whole bar is no taller than 50 dp
          expect(
            t.getSize(find.byType(AppNavBar)).height,
            lessThanOrEqualTo(50),
          );
          expect(find.byKey(const ValueKey('createButton')), findsOneWidget);
          if (sel != 3) {
            expect(find.byKey(const ValueKey('chatDot')), findsOneWidget);
          }
          if (sel != 3) {
            await t.tap(find.byIcon(Icons.chat_bubble_outline_rounded));
            expect(picked, 3);
          }
        });
      }
    }
  });
}
