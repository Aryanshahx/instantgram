import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:instantgram/core/services/account_family.dart';
import 'package:instantgram/core/services/calls.dart';
import 'package:instantgram/core/services/chat_prefs.dart';
import 'package:instantgram/core/services/content_filter.dart';
import 'package:instantgram/core/services/live_photos.dart';
import 'package:instantgram/core/services/media_service.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/chats/chat_theme.dart';
import 'package:instantgram/features/chats/data/channel_topics.dart';
import 'package:instantgram/features/chats/presentation/chat_detail_screen.dart';
import 'package:instantgram/features/chats/presentation/message_widgets.dart';
import 'package:instantgram/features/editor/media_editor_screen.dart';
import 'package:instantgram/features/editor/edit_models.dart' show ComposeMode;
import 'package:instantgram/features/reels/presentation/clips_screen.dart';
import 'package:instantgram/features/settings/presentation/accounts_screen.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/models/user_profile.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Fixes (still v0.0.1): black photo editor, clips fill the screen + no
// dots, chat theme change kept the chat working, chat background photo,
// ⋯ menu in chats, faster account switching.

UserProfile _other() =>
    UserProfile.fromMap('other', const {'username': 'sam', 'photoUrl': ''});

/// Single-listen stream like Firestore's: listening twice = error.
Stream<List<Message>> _once() {
  final c = StreamController<List<Message>>();
  c.add([
    Message.fromMap('m1', {
      'senderId': 'other',
      'text': 'hello there',
      'createdAt': Timestamp.fromDate(DateTime(2026, 10, 17)),
    }),
  ]);
  return c.stream;
}

Widget _chat(Stream<List<Message>> msgs) => MaterialApp(
  theme: AppTheme.dark,
  home: ChatDetailScreen(
    other: _other(),
    messages: msgs,
    chat: const Stream.empty(),
    myUid: 'me',
  ),
);

Future<void> _frames(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() {
    NetImage.disableCache = true;
    VoiceBubble.disabled = true;
    Calls.disabled = true;
    LivePhotos.disabled = true;
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ContentFilter.instance.debugSet(me: 'me');
    ChatPrefs.instance.debugSet(ChatPrefsData.empty);
  });

  // ------------------------------------------------------------ editor
  testWidgets('photo editor shows the photo (was black: 0 x 0)', (t) async {
    // real files: outside the test clock
    final dir = (await t.runAsync(
      () => Directory.systemTemp.createTemp('ig_editor'),
    ))!;
    final f = File('${dir.path}/p.png');
    await t.runAsync(
      () => f.writeAsBytes(img.encodePng(img.Image(width: 40, height: 30))),
    );
    await t.binding.setSurfaceSize(const Size(400, 800));
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: MediaEditorScreen(
          media: [PickedMedia(f, isVideo: false)],
          mode: ComposeMode.photo,
          onDone: (_) {},
        ),
      ),
    );
    // the photo size is read from the file (real time)
    for (var i = 0; i < 20; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump();
      if (find.byType(InteractiveViewer).evaluate().isNotEmpty) break;
    }
    final viewer = find.byType(InteractiveViewer);
    expect(viewer, findsOneWidget);
    final size = t.getSize(viewer);
    expect(size.width, greaterThan(100));
    expect(size.height, greaterThan(50));
    await t.binding.setSurfaceSize(null);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
    await t.runAsync(() => dir.delete(recursive: true));
  });

  // ------------------------------------------------------------ clips
  test('clips: 9:16 fills tall phones, square / wide stay whole', () {
    expect(ClipLayout.fillsScreen(9 / 16, 1080 / 2400), isTrue); // 20:9
    expect(ClipLayout.fillsScreen(9 / 16, 1080 / 2520), isTrue); // 21:9
    expect(ClipLayout.fillsScreen(9 / 16, 9 / 16), isTrue);
    expect(ClipLayout.fillsScreen(4 / 5, 1080 / 2400), isFalse);
    expect(ClipLayout.fillsScreen(1, 1080 / 2400), isFalse);
    expect(ClipLayout.fillsScreen(16 / 9, 1080 / 2400), isFalse);
    expect(ClipLayout.fillsScreen(0, 0.5), isFalse);
  });

  // ------------------------------------------------------------ theme
  testWidgets('new theme: chat keeps working (Firestore-like stream)', (
    t,
  ) async {
    await t.pumpWidget(_chat(_once()));
    await _frames(t);
    expect(find.text('hello there'), findsOneWidget);
    ChatPrefs.instance.debugSet(
      const ChatPrefsData(themes: {'me_other': 'ocean'}),
    );
    await _frames(t);
    expect(t.takeException(), isNull);
    expect(find.byKey(const ValueKey('chat-bg-ocean')), findsOneWidget);
    expect(find.text('hello there'), findsOneWidget);
    await t.pump(const Duration(seconds: 10));
  });

  testWidgets('background photo shows (only on this phone)', (t) async {
    await t.pumpWidget(_chat(_once()));
    await _frames(t);
    expect(find.byKey(const ValueKey('chat-bg-photo')), findsNothing);
    await t.runAsync(
      () => ChatPrefs.instance.setBackground('me_other', '/nope/bg.jpg'),
    );
    await _frames(t);
    expect(
      ChatPrefs.instance.value.value.backgroundOf('me_other'),
      '/nope/bg.jpg',
    );
    expect(find.byKey(const ValueKey('chat-bg-photo')), findsOneWidget);
    expect(find.text('hello there'), findsOneWidget);
    expect(t.takeException(), isNull);
    // other settings keep the photo
    await t.runAsync(
      () => ChatPrefs.instance
          .setVanish('me_other', Disappear.day)
          .catchError((Object _) {}),
    );
    expect(ChatPrefs.instance.value.value.backgroundOf('me_other'), isNotEmpty);
    await t.runAsync(() => ChatPrefs.instance.setBackground('me_other', null));
    await _frames(t);
    expect(find.byKey(const ValueKey('chat-bg-photo')), findsNothing);
    await t.pump(const Duration(seconds: 10));
  });

  testWidgets('theme sheet: choose / remove a background photo', (t) async {
    final saved = <String?>[];
    late BuildContext ctx;
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    Future<void> open() async {
      unawaited(
        showChatThemePicker(
          ctx,
          'me_other',
          pickPhoto: (id) async => '/x/$id.jpg',
          saveBackground: (id, path) async => saved.add(path),
        ),
      );
      await t.pumpAndSettle();
    }

    await open();
    expect(find.text('Choose photo'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-bg-remove')), findsNothing);
    await t.tap(find.byKey(const ValueKey('chat-bg-pick')));
    await t.pumpAndSettle();
    expect(saved, ['/x/me_other.jpg']);
    ChatPrefs.instance.debugSet(
      const ChatPrefsData(backgrounds: {'me_other': '/x/me_other.jpg'}),
    );
    await open();
    expect(find.text('Change photo'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('chat-bg-remove')));
    await t.pumpAndSettle();
    expect(saved.last, isNull);
  });

  testWidgets('⋯ menu: disappearing messages + chat theme', (t) async {
    await t.pumpWidget(_chat(_once()));
    await _frames(t);
    expect(find.byIcon(Icons.timer_outlined), findsNothing); // not in the bar
    await t.tap(find.byKey(const ValueKey('chat-more')));
    await t.pumpAndSettle();
    expect(find.text('Disappearing messages'), findsOneWidget);
    expect(find.text('Chat theme'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('chat-theme-btn')));
    await t.pumpAndSettle();
    expect(find.text('Only you see it'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-bg-pick')), findsOneWidget);
    await t.tapAt(const Offset(10, 10));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('chat-more')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('disappear-btn')));
    await t.pumpAndSettle();
    expect(find.text('Once seen'), findsWidgets);
    await t.tapAt(const Offset(10, 10));
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 10));
  });

  // ------------------------------------------------------------ accounts
  group('faster switching', () {
    tearDown(() {
      final f = AccountFamily.instance;
      f.clear();
      f.now = DateTime.now;
    });

    test('tokens are fetched early and used once; 45 min max', () async {
      final f = AccountFamily.instance;
      var t0 = DateTime(2026, 10, 17, 12);
      f.now = () => t0;
      final asked = <String>[];
      f.call = (body) async {
        asked.add('${body['uid']}');
        return {'token': 'tok-${body['uid']}-${asked.length}'};
      };
      await f.prefetch(['me', 'u2', 'u3'], me: 'me');
      expect(asked..sort(), ['u2', 'u3']); // not me
      asked.clear();
      expect(await f.tokenFor('u2'), startsWith('tok-u2'));
      expect(asked, isEmpty); // from the early fetch
      await f.tokenFor('u2'); // used: asks again
      expect(asked, ['u2']);
      asked.clear();
      t0 = t0.add(const Duration(minutes: 46)); // too old
      await f.tokenFor('u3');
      expect(asked, ['u3']);
      // errors are ignored, logout forgets everything
      f.call = (body) async => throw Exception('offline');
      await f.prefetch(['u4'], me: 'me');
      f.call = (body) async => {'token': 'tok-x'};
      await f.prefetch(['u5'], me: 'me');
      f.clear();
      asked.clear();
      f.call = (body) async {
        asked.add('${body['uid']}');
        return {'token': 'tok-new'};
      };
      await f.tokenFor('u5');
      expect(asked, ['u5']);
    });

    test('channel pushes stop all at once (not one by one)', () async {
      final started = <String>[];
      final gate = Completer<void>();
      final topics = ChannelTopics.instance
        ..debugSet = (topic, on) async {
          if (on) return true;
          started.add(topic);
          await gate.future;
          return true;
        };
      topics.update('me', [
        Chat.fromMap('ch_AAAAAAAAAAAAAAAAAAAA', const {
          'members': ['me'],
        }),
        Chat.fromMap('ch_BBBBBBBBBBBBBBBBBBBB', const {
          'members': ['me'],
        }),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final stop = topics.stop();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(started.length, 3); // both channels + own id, together
      gate.complete();
      await stop;
      topics.debugSet = null;
    });

    testWidgets('"Switching to @name…" shows at once, then goes', (t) async {
      late BuildContext ctx;
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (c) {
                ctx = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      final done = showSwitching(ctx, 'second');
      await t.pump();
      expect(find.text('Switching to @second…'), findsOneWidget);
      done();
      await t.pump();
      expect(find.byKey(const ValueKey('switching')), findsNothing);
      done(); // twice is fine
    });
  });
}
