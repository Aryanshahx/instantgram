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

    testWidgets('Post: the audio bar is under the preview', (t) async {
      await open(t);
      expect(find.byKey(const ValueKey('audioBar')), findsOneWidget);
      expect(find.text('Add audio'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('audioBar')));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('No audio yet'), findsOneWidget);
      expect(find.text('Choose'), findsOneWidget);
      expect(find.text('Length'), findsNothing); // only for photo clips
      expect(t.takeException(), isNull);
    });

    testWidgets('Clips: any photo works, audio is needed, length shown', (
      t,
    ) async {
      await open(t);
      await t.tap(find.text('Clips'));
      await t.pump(const Duration(milliseconds: 300));
      // the photo picked in Post became a photo clip; no Video / Photo switch
      expect(find.text('Photo + music'), findsNothing);
      expect(find.text('Add audio to make this a clip'), findsOneWidget);
      await t.tap(find.text('Next'));
      await t.pump(const Duration(milliseconds: 400));
      expect(
        find.text('Add audio to make a clip from a photo.'),
        findsOneWidget,
      );
      expect(find.text('Audio'), findsOneWidget);
      expect(find.text('Length'), findsOneWidget);
      expect(find.text('10s'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('Publish stays off until there is a title', (t) async {
      await open(t);
      await t.tap(find.text('Next'));
      await t.pump(const Duration(milliseconds: 300));
      FilledButton publish() => t.widget<FilledButton>(
        find
            .ancestor(
              of: find.text('Publish'),
              matching: find.bySubtype<FilledButton>(),
            )
            .first,
      );
      expect(find.text('Title'), findsOneWidget);
      expect(publish().onPressed, isNull);
      await t.enterText(find.byType(TextField), '   ');
      await t.pump();
      expect(publish().onPressed, isNull);
      await t.enterText(find.byType(TextField), 'Sunset');
      await t.pump();
      expect(publish().onPressed, isNotNull);
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
