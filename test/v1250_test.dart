import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/l10n.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/app_notification.dart';
import 'package:instantgram/models/chat.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/screens/chat/chat_options_sheet.dart';
import 'package:instantgram/screens/chat/chat_peek_sheet.dart';
import 'package:instantgram/services/post_service.dart';
import 'package:instantgram/widgets/like_button.dart';
import 'package:instantgram/widgets/post_actions_sheet.dart';

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark,
  home: Scaffold(body: child),
);

ChatMessage _m(
  String id,
  String from,
  String text, {
  List<String> hidden = const [],
}) => ChatMessage(
  id: id,
  senderId: from,
  text: text,
  createdAt: DateTime(2026, 10, 8, 12),
  hiddenFor: hidden,
);

/// Records the like writes; [fail] makes them throw.
class _FakeLikes {
  bool liked = false;
  bool superHeart = false;
  bool fail = false;
  final List<String> calls = [];

  LikeApi get api => LikeApi(
    state: (_) async => (liked: liked, superHeart: superHeart),
    setLike: (id, like, wasSuper) async {
      if (fail) throw StateError('offline');
      calls.add('like:$like:$wasSuper');
    },
    sendSuper: (id, already) async {
      if (fail) throw StateError('offline');
      calls.add('super:$already');
    },
  );
}

void main() {
  late _FakeLikes likes;
  setUp(() {
    likes = _FakeLikes();
    LikeApi.debug = likes.api;
  });
  tearDown(() {
    LikeApi.debug = null;
    debugPeekMessages = null;
  });

  group('peek', () {
    testWidgets('shows the chat without opening it; hidden messages left out', (
      t,
    ) async {
      debugPeekMessages = (_) => Stream.value([
        _m('3', 'zoe', 'are you there?'),
        _m('2', 'me', 'deleted for me', hidden: ['me']),
        _m('1', 'me', 'hi'),
      ]);
      var opened = false;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showChatPeek(
                ctx,
                chatId: 'c',
                myUid: 'me',
                name: 'zoe',
                onOpenChat: () => opened = true,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await _settle(t);
      expect(find.byKey(const ValueKey('peekNote')), findsOneWidget);
      expect(find.text('are you there?'), findsOneWidget);
      expect(find.text('hi'), findsOneWidget);
      expect(find.text('deleted for me'), findsNothing);
      await t.tap(find.byKey(const ValueKey('peekOpen')));
      await _settle(t);
      expect(opened, isTrue);
      expect(find.byKey(const ValueKey('peekList')), findsNothing);
    });

    testWidgets('holding a chat offers Peek first', (t) async {
      ChatOption? got;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (ctx) => TextButton(
              onPressed: () async => got = await showChatOptions(
                ctx,
                thread: const ChatThread(id: 'c', members: ['me', 'zoe']),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await _settle(t);
      await t.tap(find.byKey(const ValueKey('chatPeek')));
      await _settle(t);
      expect(got, ChatOption.peek);
    });
  });

  group('super hearts', () {
    test('a super heart also likes, once per person', () async {
      final c = LikeController('p', 4);
      await Future<void>.delayed(Duration.zero);
      expect(await c.sendSuper(), isTrue);
      expect(c.liked, isTrue);
      expect(c.count, 5);
      expect(c.superCount, 1);
      expect(await c.sendSuper(), isFalse);
      expect(likes.calls, ['super:false']);
    });

    test('on a liked post it does not count the like twice', () async {
      likes.liked = true;
      final c = LikeController('p', 4);
      await Future<void>.delayed(Duration.zero);
      await c.sendSuper();
      expect(c.count, 4);
      expect(likes.calls, ['super:true']);
    });

    test('unliking takes the super heart back too', () async {
      likes
        ..liked = true
        ..superHeart = true;
      final c = LikeController('p', 4, superCount: 2);
      await Future<void>.delayed(Duration.zero);
      expect(c.superHeart, isTrue);
      await c.setLiked(false);
      expect(c.superHeart, isFalse);
      expect(c.superCount, 1);
      expect(c.count, 3);
      expect(likes.calls, ['like:false:true']);
    });

    test('a failed super heart is rolled back', () async {
      likes.fail = true;
      final c = LikeController('p', 4);
      await Future<void>.delayed(Duration.zero);
      await expectLater(c.sendSuper(), throwsStateError);
      expect(c.superHeart, isFalse);
      expect(c.liked, isFalse);
      expect(c.count, 4);
      expect(c.superCount, 0);
    });

    testWidgets('hold the heart: burst, purple heart, count', (t) async {
      final c = LikeController('p', 4);
      await t.pumpWidget(_app(Center(child: HeartButton(controller: c))));
      await _settle(t);
      expect(find.byKey(const ValueKey('superCount')), findsNothing);
      await t.longPress(find.byType(HeartButton));
      await t.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('superBurst')), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
      expect(find.byKey(const ValueKey('superBurst')), findsNothing);
      expect(find.text('5'), findsOneWidget);
      expect(find.byKey(const ValueKey('superCount')), findsOneWidget);
      final icon = t.widget<Icon>(find.byIcon(Icons.favorite_rounded));
      expect(icon.color, kSuperHeartColor);

      await t.longPress(find.byType(HeartButton)); // a second one: just a note
      await t.pump(const Duration(milliseconds: 200));
      expect(find.text('You already sent a super heart here.'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
      c.dispose();
    });

    test('activity line', () {
      expect(
        const AppNotification(id: 'n', type: 'super').verb,
        'sent you a super heart 💖',
      );
    });
  });

  group('pins and profile-only posts', () {
    test('six pins', () => expect(PostService.maxPins, 6));

    test('options carry profile-only', () {
      expect(const PostOptions(profileOnly: true).toMap()['profileOnly'], true);
      expect(const PostOptions().toMap()['profileOnly'], false);
    });

    testWidgets('my post menu: only on my profile / back to Home', (t) async {
      await t.binding.setSurfaceSize(const Size(500, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      Future<void> show(bool profileOnly) async {
        final p = Post(
          id: 'p1',
          authorId: 'me',
          authorUsername: 'me',
          authorPhotoUrl: '',
          type: 'image',
          caption: '',
          createdAt: DateTime(2026),
          profileOnly: profileOnly,
        );
        await t.pumpWidget(
          LanguageScope(
            language: Language.instance,
            child: MaterialApp(
              theme: AppTheme.light,
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showPostActions(context, p, myUid: 'me'),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.text('open'));
        await t.pump(const Duration(milliseconds: 500));
      }

      await show(false);
      expect(find.text('Only on my profile'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await show(true);
      expect(find.text('Show in Home and Explore'), findsOneWidget);
    });
  });
}
