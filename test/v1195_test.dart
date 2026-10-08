import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:instantgram/core/app_info.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/chat.dart';
import 'package:instantgram/screens/chat/chat_options_sheet.dart';
import 'package:instantgram/screens/settings/delete_account_screen.dart';

ChatThread _thread({
  bool pinned = false,
  bool muteCalls = false,
  bool muteMessages = false,
}) =>
    ChatThread(
      id: 'a_b',
      members: const ['a', 'b'],
      lastText: 'hello',
      pinned: pinned,
      muteCalls: muteCalls,
      muteMessages: muteMessages,
    );


/// The test screen is small by default; the sheets need room.
void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}


Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('the email that asks for an account to be deleted', () {
    test('it goes to the support address and carries who you are', () {
      final uri = deleteRequestMailto(
        username: 'aryan',
        email: 'me@example.com',
        uid: 'uid42',
      );
      expect(uri.scheme, 'mailto');
      expect(uri.path, kSupportEmail);
      expect(uri.queryParameters['subject'], contains('Delete my'));
      expect(uri.queryParameters['subject'], contains(kAppName));
      final body = uri.queryParameters['body']!;
      expect(body, contains('@aryan'));
      expect(body, contains('me@example.com'));
      expect(body, contains('uid42'));
    });

    testWidgets('the screen explains what goes and offers the email',
        (tester) async {
      _tall(tester);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark, home: const DeleteAccountScreen()),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('deleteRequestButton')), findsOneWidget);
      expect(find.byKey(const ValueKey('deleteCopyButton')), findsOneWidget);
      expect(find.text('What is removed'), findsOneWidget);
      expect(find.textContaining('Your chats and messages'), findsOneWidget);
      expect(
        find.textContaining('The sign-in itself, so the email and password stop working'),
        findsOneWidget,
      );
      expect(find.textContaining(kSupportEmail), findsWidgets);
    });
  });

  group('holding a chat', () {
    Future<ChatOption?> open(WidgetTester tester, ChatThread t) async {
      ChatOption? picked;
      _tall(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    picked = await showChatOptions(c, thread: t, name: 'riya');
                  },
                  child: const Text('hold'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('hold'));
      await _settle(tester);
      return picked;
    }

    testWidgets('it offers pin, mute calls, mute messages and delete',
        (tester) async {
      await open(tester, _thread());
      expect(find.text('riya'), findsOneWidget);
      expect(find.byKey(const ValueKey('chatPin')), findsOneWidget);
      expect(find.byKey(const ValueKey('chatMuteCalls')), findsOneWidget);
      expect(find.byKey(const ValueKey('chatMuteMessages')), findsOneWidget);
      expect(find.byKey(const ValueKey('chatDelete')), findsOneWidget);
      expect(find.text('Pin to the top'), findsOneWidget);
      expect(find.text('Mute calls'), findsOneWidget);
      expect(find.text('Mute messages'), findsOneWidget);
      expect(find.text('Delete chat'), findsOneWidget);
    });

    testWidgets('each choice comes back as what it is', (tester) async {
      _tall(tester);
      ChatOption? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    picked = await showChatOptions(c, thread: _thread());
                  },
                  child: const Text('hold'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('hold'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('chatPin')));
      await _settle(tester);
      expect(picked, ChatOption.pin);

      await tester.tap(find.text('hold'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('chatMuteCalls')));
      await _settle(tester);
      expect(picked, ChatOption.muteCalls);

      await tester.tap(find.text('hold'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('chatMuteMessages')));
      await _settle(tester);
      expect(picked, ChatOption.muteMessages);

      await tester.tap(find.text('hold'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('chatDelete')));
      await _settle(tester);
      expect(picked, ChatOption.delete);
    });

    testWidgets('a chat that is already pinned or muted says the opposite',
        (tester) async {
      _tall(tester);
      await open(
        tester,
        _thread(pinned: true, muteCalls: true, muteMessages: true),
      );
      expect(find.text('Unpin'), findsOneWidget);
      expect(find.text('Unmute calls'), findsOneWidget);
      expect(find.text('Unmute messages'), findsOneWidget);
    });
  });
}
