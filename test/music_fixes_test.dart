// Music update + fixes: songs ("use this audio", library, AI songs),
// pin only on the profile, built-in chat backgrounds, reactions "+",
// more comment emojis.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/services/api_client.dart';
import 'package:instantgram/core/services/media_service.dart';
import 'package:instantgram/core/services/music_player.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/chats/chat_theme.dart';
import 'package:instantgram/features/chats/chat_wallpapers.dart';
import 'package:instantgram/features/chats/presentation/message_widgets.dart';
import 'package:instantgram/features/music/data/music_repository.dart';
import 'package:instantgram/features/music/presentation/music_picker_sheet.dart';
import 'package:instantgram/features/music/presentation/music_screen.dart';
import 'package:instantgram/features/post/data/post_repository.dart';
import 'package:instantgram/features/post/data/upload_queue.dart';
import 'package:instantgram/features/post/presentation/comments_sheet.dart';
import 'package:instantgram/shared/models/music.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/widgets/emoji_picker.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:instantgram/shared/widgets/post_grid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark,
  home: Scaffold(body: child),
);

Future<void> _frames(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _finish(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 1));
}

MusicTrack _track(
  String id, {
  String title = 'Song',
  String artist = 'Studio',
  String mood = 'happy',
  int uses = 0,
  bool hidden = false,
  String source = MusicTrack.library,
  int created = 0,
}) => MusicTrack.fromMap(id, {
  'source': source,
  'title': title,
  'artist': artist,
  'mood': mood,
  'url': 'https://b.t3.tigrisfiles.io/music/$id.mp3',
  'durationMs': 65000,
  'uses': uses,
  'hidden': hidden,
  'createdAt': Timestamp.fromMillisecondsSinceEpoch(1000000 + created),
});

Post _post(String id, {Map<String, dynamic> extra = const {}}) =>
    Post.fromMap(id, {
      'authorId': 'amit',
      'authorUsername': 'amit',
      'type': 'clip',
      'mediaUrl': 'https://x/$id.jpg',
      'caption': '',
      ...extra,
    });

void main() {
  setUp(() {
    MusicPlayer.disabled = true;
    NetImage.disableCache = true;
    MusicRepository.debugLibrary = null;
    MusicRepository.debugMySongs = null;
    MusicRepository.debugTrack = null;
    MusicRepository.debugPostsWith = null;
    MusicScreen.debugUse = null;
    MusicRepository.instance.debugReset();
  });

  // ------------------------------------------------------------- models
  group('songs', () {
    test('MusicTrack reads a song doc', () {
      final t = _track('lib_1', title: 'Sunny', artist: 'Studio');
      expect(t.label, 'Sunny · Studio');
      expect(t.isAi, isFalse);
      expect(MusicTrack.fromMap('x', const {}).title, 'Song');
      final ai = MusicTrack.fromMap('ai_1', {
        'source': 'ai',
        'title': 'Rain',
        'artist': '',
        'createdAt': '2026-10-17T10:00:00.000Z',
      });
      expect(ai.isAi, isTrue);
      expect(ai.label, 'Rain');
      expect(ai.createdAt, isNotNull);
    });

    test('library order: most used, then newest; hidden left out', () {
      final list = sortTracks([
        _track('a', uses: 1, created: 1),
        _track('b', uses: 5),
        _track('c', uses: 1, created: 9),
        _track('d', uses: 99, hidden: true),
      ]);
      expect(list.map((t) => t.id), ['b', 'c', 'a']);
    });

    test('search in name, artist and mood', () {
      final all = [
        _track('a', title: 'Sunny Day', artist: 'Kay', mood: 'happy'),
        _track('b', title: 'Night', artist: 'Lofi Boy', mood: 'chill'),
      ];
      expect(searchTracks(all, 'sunny').map((t) => t.id), ['a']);
      expect(searchTracks(all, 'lofi chill').map((t) => t.id), ['b']);
      expect(searchTracks(all, '  ').length, 2);
      expect(searchTracks(all, 'rock'), isEmpty);
    });

    test('times', () {
      expect(trackTime(0), '');
      expect(trackTime(65000), '1:05');
      expect(trackTime(30000), '0:30');
    });

    test('post reads its song + start; shared song file is kept', () {
      final p = _post(
        'p1',
        extra: {
          'audioUrl': 'https://x/a.mp3',
          'audioKey': 'audio/amit/a.mp3',
          'musicId': 'o_p1',
          'audioStartMs': 12000,
        },
      );
      expect(p.musicId, 'o_p1');
      expect(p.audioStartMs, 12000);
      expect(p.allKeys, isNot(contains('audio/amit/a.mp3')));
      final own = _post(
        'p2',
        extra: {
          'audioUrl': 'https://x/b.mp3',
          'audioKey': 'audio/amit/b.mp3',
        },
      );
      expect(own.allKeys, contains('audio/amit/b.mp3'));
    });

    test('which song page a new post links to', () {
      expect(
        PostRepository.musicLink(
          postId: 'p9',
          musicId: '',
          audioKey: 'audio/me/a.mp3',
        ),
        (id: 'o_p9', create: true),
      );
      expect(
        PostRepository.musicLink(postId: 'p9', musicId: 'lib_1', audioKey: ''),
        (id: 'lib_1', create: false),
      );
      expect(
        PostRepository.musicLink(postId: 'p9', musicId: '', audioKey: ''),
        isNull,
      );
      expect(
        PostRepository.musicLink(postId: 'p9', musicId: 'a/b', audioKey: ''),
        isNull,
      );
    });

    test('online song: nothing to upload, saved in the queue', () {
      final a = PickedAudio.online(
        url: 'https://x/s.mp3',
        name: 'Sunny · Studio',
        musicId: 'lib_1',
        durationMs: 60000,
      );
      expect(a.isOnline, isTrue);
      expect(a.source, 'https://x/s.mp3');
      final b = a.withStart(15000);
      expect(b.startMs, 15000);
      expect(b.musicId, 'lib_1');
      expect(a.withStart(-5).startMs, 0);

      final task = UploadTask(
        id: 't1',
        kind: UploadTask.clip,
        items: [QueuedMedia(path: '/x/v.mp4', isVideo: true)],
        audioName: 'Sunny · Studio',
        audioUrl: 'https://x/s.mp3',
        musicId: 'lib_1',
        audioStartMs: 15000,
        audioDurationMs: 60000,
      );
      final back = UploadTask.fromJson(task.toJson())!;
      expect(back.audioUrl, 'https://x/s.mp3');
      expect(back.musicId, 'lib_1');
      expect(back.audioStartMs, 15000);
      expect(back.audioDurationMs, 60000);
      expect(back.audioPath, isNull);
    });

    test('SongInfo', () {
      final i = SongInfo.fromMap(const {'enabled': true, 'left': 2});
      expect(i.enabled, isTrue);
      expect(i.left, 2);
      expect(i.perDay, 3);
      expect(i.fullCost, 2);
      expect(SongInfo.fromMap(const {}).enabled, isFalse);
    });
  });

  // ----------------------------------------------------------- picker
  group('music picker', () {
    testWidgets('library: list, search, Use', (t) async {
      MusicRepository.debugLibrary = () async => [
        _track('lib_1', title: 'Sunny Day', artist: 'Kay', uses: 3),
        _track('lib_2', title: 'Night Drive', artist: 'Lofi', mood: 'chill'),
      ];
      MusicRepository.instance.call = (body, timeout) async =>
          {'enabled': false, 'left': 0, 'perDay': 3};
      late BuildContext ctx;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      PickedAudio? got;
      unawaited(showMusicPicker(ctx).then((a) => got = a));
      await _frames(t);
      expect(find.text('Sunny Day'), findsOneWidget);
      expect(find.text('Night Drive'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('music-search')), 'chill');
      await _frames(t, 2);
      expect(find.text('Sunny Day'), findsNothing);
      await t.tap(find.byKey(const ValueKey('track-use-lib_2')));
      await _frames(t);
      expect(got, isNotNull);
      expect(got!.isOnline, isTrue);
      expect(got!.musicId, 'lib_2');
      expect(got!.name, 'Night Drive · Lofi');
      expect(got!.durationMs, 65000);
      await _finish(t);
    });

    testWidgets('AI song: N left today, make, then use it', (t) async {
      MusicRepository.debugLibrary = () async => const [];
      MusicRepository.debugMySongs = () async => const [];
      final calls = <Map<String, dynamic>>[];
      MusicRepository.instance.call = (body, timeout) async {
        calls.add(body);
        if (body['action'] == 'songInfo') {
          return {'enabled': true, 'left': 3, 'perDay': 3, 'fullCost': 2};
        }
        expect(timeout, greaterThan(const Duration(minutes: 2)));
        return {
          'id': 'ai_abc',
          'source': 'ai',
          'title': 'Happy bike ride',
          'artist': '@me',
          'url': 'https://x/ai.mp3',
          'durationMs': 30000,
          'left': 2,
          'perDay': 3,
        };
      };
      late BuildContext ctx;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      PickedAudio? got;
      unawaited(showMusicPicker(ctx).then((a) => got = a));
      await _frames(t);
      await t.tap(find.byKey(const ValueKey('music-tab-ai')));
      await t.pumpAndSettle();
      expect(find.text('3 left today · new songs every day'), findsOneWidget);
      await t.enterText(
        find.byKey(const ValueKey('ai-idea')),
        'happy bike ride',
      );
      await t.tap(find.byKey(const ValueKey('ai-instrumental')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('ai-make')));
      await _frames(t);
      expect(calls.last['action'], 'song');
      expect(calls.last['prompt'], 'happy bike ride');
      expect(calls.last['instrumental'], isTrue);
      expect(calls.last['full'], isFalse);
      expect(find.text('2 left today · new songs every day'), findsOneWidget);
      expect(find.text('My AI songs'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('track-use-ai_abc')));
      await _frames(t);
      expect(got?.musicId, 'ai_abc');
      expect(got?.url, 'https://x/ai.mp3');
      await _finish(t);
    });

    testWidgets('AI song: limit message from the server', (t) async {
      MusicRepository.debugLibrary = () async => const [];
      MusicRepository.debugMySongs = () async => const [];
      MusicRepository.instance.call = (body, timeout) async {
        if (body['action'] == 'songInfo') {
          return {'enabled': true, 'left': 1, 'perDay': 3, 'fullCost': 2};
        }
        throw const ApiException(
          'You made 3 songs today. Come back tomorrow.',
          statusCode: 429,
        );
      };
      late BuildContext ctx;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      unawaited(showMusicPicker(ctx));
      await _frames(t);
      await t.tap(find.byKey(const ValueKey('music-tab-ai')));
      await t.pumpAndSettle();
      // full song needs 2, only 1 left -> button off
      await t.tap(find.byKey(const ValueKey('ai-full')));
      await t.pump();
      final btn = t.widget<ButtonStyleButton>(
        find.byKey(const ValueKey('ai-make')),
      );
      expect(btn.onPressed, isNull);
      await t.tap(find.byKey(const ValueKey('ai-full')));
      await t.pump();
      await t.enterText(find.byKey(const ValueKey('ai-idea')), 'rainy lofi');
      await t.tap(find.byKey(const ValueKey('ai-make')));
      await _frames(t);
      expect(
        find.text('You made 3 songs today. Come back tomorrow.'),
        findsOneWidget,
      );
      await _finish(t);
    });

    testWidgets('start slider shows where the song starts', (t) async {
      int? end;
      await t.pumpWidget(
        _app(
          MusicStartSlider(
            startMs: 65000,
            lengthMs: 120000,
            onChanged: (_) {},
            onChangeEnd: (v) => end = v,
          ),
        ),
      );
      expect(find.text('Starts 1:05'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('music-start')));
      await t.pump();
      expect(end, isNotNull);
      // too short song -> no slider
      await t.pumpWidget(
        _app(
          MusicStartSlider(
            startMs: 0,
            lengthMs: 4000,
            onChanged: (_) {},
            onChangeEnd: (_) {},
          ),
        ),
      );
      expect(find.byKey(const ValueKey('music-start')), findsNothing);
    });
  });

  // -------------------------------------------------------- song page
  group('song page', () {
    testWidgets('title, shares, Use this audio (keeps the start)', (t) async {
      MusicRepository.debugTrack = (id) async =>
          _track(id, title: 'Sunny Day', artist: 'Kay', uses: 2);
      MusicRepository.debugPostsWith = (id) async => [
        _post('c1', extra: {'musicId': id, 'audioUrl': 'https://x/a.mp3'}),
        _post('c2', extra: {'musicId': id, 'audioUrl': 'https://x/a.mp3'}),
      ];
      PickedAudio? used;
      MusicScreen.debugUse = (a) => used = a;
      final from = _post(
        'c1',
        extra: {
          'musicId': 'lib_1',
          'audioUrl': 'https://x/a.mp3',
          'audioStartMs': 9000,
        },
      );
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: MusicScreen(musicId: 'lib_1', from: from),
        ),
      );
      await _frames(t);
      expect(find.text('Sunny Day'), findsOneWidget);
      expect(find.text('Kay'), findsOneWidget);
      expect(find.text('Happy · 2 shares'), findsOneWidget);
      expect(find.byKey(const ValueKey('grid-c1')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('music-use')));
      await _frames(t, 2);
      expect(used?.musicId, 'lib_1');
      expect(used?.startMs, 9000);
      expect(used?.isOnline, isTrue);
      await _finish(t);
    });

    testWidgets('removed song: no Use button', (t) async {
      MusicRepository.debugTrack = (id) async => _track(id, hidden: true);
      MusicRepository.debugPostsWith = (id) async => const [];
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const MusicScreen(musicId: 'lib_9'),
        ),
      );
      await _frames(t);
      expect(find.byKey(const ValueKey('music-page-missing')), findsOneWidget);
      expect(find.byKey(const ValueKey('music-use')), findsNothing);
      await _finish(t);
    });
  });

  // -------------------------------------------------------------- pin
  testWidgets('pin shows only where asked (profile grid)', (t) async {
    final posts = [
      _post('p1', extra: {'pinned': true, 'type': 'photo'}),
    ];
    Widget grid(bool pin) => _app(
      PostGrid(
        posts: posts,
        onTap: (_) {},
        showPinned: pin,
        emptyIcon: Icons.grid_on,
        emptyTitle: 'none',
      ),
    );
    await t.pumpWidget(grid(false));
    await _frames(t, 2);
    expect(find.byIcon(Icons.push_pin), findsNothing);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(grid(true));
    await _frames(t, 2);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    await _finish(t);
  });

  // --------------------------------------------------- chat backgrounds
  group('chat backgrounds', () {
    test('12 doodles + 12 gradients, unique ids', () {
      expect(ChatWallpaper.doodles.length, 12);
      expect(ChatWallpaper.gradients.length, 12);
      final ids = ChatWallpaper.all.map((w) => w.id).toSet();
      expect(ids.length, 24);
      expect(ChatWallpaper.doodles.every((w) => w.isDoodle), isTrue);
      expect(ChatWallpaper.gradients.every((w) => !w.isDoodle), isTrue);
      expect(ChatWallpaper.fromValue('wp:d_love')?.name, 'Love');
      expect(ChatWallpaper.fromValue('/x/photo.jpg'), isNull);
      expect(ChatWallpaper.fromValue('wp:nope'), isNull);
      expect(ChatWallpaper.isWallpaper('wp:nope'), isTrue);
    });

    testWidgets('drawn in the chat', (t) async {
      await t.pumpWidget(
        _app(
          const ChatBackground(theme: ChatTheme.lime, photo: 'wp:d_space'),
        ),
      );
      expect(find.byKey(const ValueKey('chat-wp-d_space')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-bg-photo')), findsNothing);
      await t.pumpWidget(
        _app(
          const ChatBackground(theme: ChatTheme.lime, photo: 'wp:g_ocean'),
        ),
      );
      expect(find.byKey(const ValueKey('chat-wp-g_ocean')), findsOneWidget);
      expect(t.takeException(), isNull);
      // unknown built-in -> theme colours, no crash
      await t.pumpWidget(
        _app(const ChatBackground(theme: ChatTheme.lime, photo: 'wp:zzz')),
      );
      expect(find.byKey(const ValueKey('chat-bg-lime')), findsOneWidget);
      await _finish(t);
    });

    testWidgets('picked in the theme sheet', (t) async {
      final saved = <String?>[];
      late BuildContext ctx;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      unawaited(
        showChatThemePicker(
          ctx,
          'me_other',
          saveBackground: (id, path) async => saved.add(path),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-wp-doodles')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-wp-gradients')), findsOneWidget);
      await t.ensureVisible(
        find.byKey(const ValueKey('chat-wp-pick-d_classic')),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('chat-wp-pick-d_classic')));
      await t.pumpAndSettle();
      expect(saved, ['wp:d_classic']);
      await _finish(t);
    });
  });

  // -------------------------------------------------------- reactions
  group('reactions', () {
    test('quick reactions: 6, no repeats, defaults fill gaps', () {
      expect(QuickReactions.cleanQuick(const []), QuickReactions.defaults);
      final q = QuickReactions.cleanQuick(const ['🔥', '🔥', 'abc', '😂']);
      expect(q.length, 6);
      expect(q.first, '🔥');
      expect(q.where((e) => e == '😂').length, 1);
      expect(QuickReactions.validEmoji('❤️'), isTrue);
      expect(QuickReactions.validEmoji('👍🏽'), isTrue);
      expect(QuickReactions.validEmoji('ab'), isFalse);
      expect(QuickReactions.validEmoji(''), isFalse);
      expect(kReactEmojis, QuickReactions.defaults);
    });

    test('every emoji in the picker is one emoji', () {
      var n = 0;
      for (final g in kEmojiGroups) {
        final list = emojisOf(g.$3);
        expect(list.toSet().length, list.length, reason: g.$1);
        for (final e in list) {
          expect(QuickReactions.validEmoji(e), isTrue, reason: '${g.$1} $e');
        }
        n += list.length;
      }
      expect(n, greaterThan(800));
    });

    testWidgets('"+" opens every emoji; swap a quick one', (t) async {
      SharedPreferences.setMockInitialValues({});
      QuickReactions.instance.debugReset();
      MessageMenuResult? r;
      late BuildContext ctx;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      Future<void> open() async {
        unawaited(
          showMessageMenu(
            ctx,
            message: Message.fromMap('m1', {
              'senderId': 'bob',
              'text': 'hi',
              'createdAt': Timestamp.fromDate(DateTime(2026, 10, 17)),
            }),
            mine: false,
            pinned: false,
          ).then((v) => r = v),
        );
        await t.pumpAndSettle();
      }

      await open();
      expect(find.byKey(const ValueKey('react-more')), findsOneWidget);
      expect(find.byKey(const ValueKey('react-❤️')), findsOneWidget);
      // + -> pick 🔥 -> reacts with it
      await t.tap(find.byKey(const ValueKey('react-more')));
      await t.pumpAndSettle();
      expect(find.text('Your quick reactions'), findsOneWidget);
      // 🔥 is further down (Animals): scroll to it
      await t.ensureVisible(find.byKey(const ValueKey('emoji-pick-🔥')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('emoji-pick-🔥')));
      await t.pumpAndSettle();
      expect(r?.emoji, '🔥');
      expect(QuickReactions.instance.recent.value.first, '🔥');

      // swap slot 0 (❤️) for 🤣
      await open();
      await t.tap(find.byKey(const ValueKey('react-more')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('quick-slot-0')));
      await t.pump();
      expect(find.text('Now tap the new emoji'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('emoji-pick-🤣')));
      await t.pumpAndSettle();
      expect(QuickReactions.instance.emojis.value.first, '🤣');
      // still in the picker (no reaction yet)
      expect(find.text('Your quick reactions'), findsOneWidget);
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      await open();
      expect(find.byKey(const ValueKey('react-🤣')), findsOneWidget);
      expect(find.byKey(const ValueKey('react-❤️')), findsNothing);
      await t.tap(find.byKey(const ValueKey('react-🤣')));
      await t.pumpAndSettle();
      expect(r?.emoji, '🤣');
      QuickReactions.instance.debugReset();
      await _finish(t);
    });
  });

  // --------------------------------------------------------- comments
  test('24 comment emojis, all different', () {
    expect(kCommentEmojis.length, 24);
    expect(kCommentEmojis.toSet().length, 24);
    expect(kCommentEmojis.take(3), ['❤️', '🙌', '🔥']);
  });
}
