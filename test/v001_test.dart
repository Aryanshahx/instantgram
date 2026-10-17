import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:instantgram/core/config/app_info.dart';
import 'package:instantgram/core/navigation/page_cover.dart';
import 'package:instantgram/core/services/chat_prefs.dart';
import 'package:instantgram/core/services/notice_push.dart';
import 'package:instantgram/core/services/watch_clock.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/chats/chat_theme.dart';
import 'package:instantgram/features/post/presentation/comments_sheet.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/widgets/net_image.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark,
  navigatorObservers: [PageCover.instance],
  home: Scaffold(body: child),
);

Post _post() => Post(
  id: 'p1',
  authorId: 'author',
  authorUsername: 'author',
  authorPhotoUrl: '',
  type: Post.clip,
  mediaUrl: 'https://x.test/a.jpg',
  mediaKey: '',
  caption: '',
  aspectRatio: 1,
  likesCount: 0,
  commentsCount: 0,
  repostsCount: 0,
  viewsCount: 0,
  pinned: false,
  createdAt: DateTime(2026, 1, 1),
);

Comment _c(String id, {String parent = ''}) => Comment(
  id: id,
  authorId: 'bob',
  authorUsername: 'bob',
  authorPhotoUrl: '',
  text: 'hi $id',
  createdAt: DateTime(2026, 1, 1),
  parentId: parent,
  likesCount: 0,
  gifUrl: '',
  gifW: 0,
  gifH: 0,
);

void main() {
  setUpAll(() => NetImage.disableCache = true);

  // ------------------------------------------------------------ version
  test('version 0.0.x for the app and Hyper Intelligence', () {
    expect(AppInfo.version, matches(RegExp(r'^0\.0\.\d+$')));
    expect(AppInfo.hiVersion, AppInfo.version);
  });

  // ------------------------------------------------------------ views 3 s
  group('WatchClock: a view after 3 s of real watching', () {
    test('counts once, after 3 s of playing', () {
      final w = WatchClock();
      expect(WatchClock.viewAfterMs, 3000);
      var fired = 0;
      for (var t = 0; t <= 2900; t += 100) {
        if (w.update(playing: true, nowMs: t)) fired++;
      }
      expect(fired, 0);
      expect(w.done, isFalse);
      if (w.update(playing: true, nowMs: 3000)) fired++;
      expect(fired, 1);
      // never again (rewatch / loop)
      for (var t = 3100; t <= 9000; t += 100) {
        if (w.update(playing: true, nowMs: t, completed: true)) fired++;
      }
      expect(fired, 1);
    });

    test('paused / loading time does not count', () {
      final w = WatchClock();
      w.update(playing: true, nowMs: 0);
      w.update(playing: true, nowMs: 1000);
      w.pause(2000); // 1 s more until the pause -> 2 s
      expect(w.playedMs, 2000);
      // 10 s paused
      expect(w.update(playing: false, nowMs: 12000), isFalse);
      expect(w.playedMs, 2000);
      w.update(playing: true, nowMs: 12000);
      expect(w.update(playing: true, nowMs: 12900), isFalse);
      expect(w.update(playing: true, nowMs: 13000), isTrue);
    });

    test('phone asleep: a big jump counts at most 1 s', () {
      final w = WatchClock();
      w.update(playing: true, nowMs: 0);
      expect(w.update(playing: true, nowMs: 60000), isFalse);
      expect(w.playedMs, 1000);
    });

    test('a short video counts when it reached the end', () {
      final w = WatchClock();
      w.update(playing: true, nowMs: 0);
      expect(w.update(playing: false, nowMs: 1500, completed: true), isTrue);
    });

    test('nothing played -> no view', () {
      final w = WatchClock();
      expect(w.update(playing: false, nowMs: 0), isFalse);
      expect(w.update(playing: false, nowMs: 5000), isFalse);
      expect(w.done, isFalse);
    });
  });

  // ------------------------------------------------------------ chat theme
  group('chat theme (only I see it)', () {
    test('10 themes, unique, lime is default', () {
      final ids = ChatTheme.all.map((t) => t.id).toList();
      expect(ids.length, 10);
      expect(ids.toSet().length, 10);
      expect(ChatTheme.defaultId, 'lime');
      expect(ChatTheme.byId(null).id, 'lime');
      expect(ChatTheme.byId('nope').id, 'lime');
      expect(ChatTheme.byId('ocean').id, 'ocean');
    });

    test('text on my bubble is readable', () {
      double ratio(Color a, Color b) {
        final x = a.computeLuminance();
        final y = b.computeLuminance();
        return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
      }

      for (final t in ChatTheme.all) {
        expect(ratio(t.mine, t.mineText), greaterThan(3.5), reason: t.id);
        final m2 = t.mine2;
        if (m2 != null) {
          expect(ratio(m2, t.mineText), greaterThan(3.5), reason: '${t.id} 2');
        }
      }
    });

    test('saved per chat (prefs doc)', () {
      final d = ChatPrefsData.fromMap({
        'chatThemes': {'c1': 'ocean', 'c2': '', 'c3': 5},
      });
      expect(d.themeOf('c1'), 'ocean');
      expect(d.themeOf('c2'), 'lime');
      expect(d.themeOf('c3'), 'lime');
      expect(d.themeOf('other'), 'lime');
      expect(ChatPrefsData.fromMap({}).themeOf('c1'), 'lime');
    });

    testWidgets('picker saves the tapped theme; scope gives it', (t) async {
      final saved = <String>[];
      String? picked;
      ChatTheme? seen;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (c) => Column(
              children: [
                TextButton(
                  onPressed: () async {
                    picked = await showChatThemePicker(
                      c,
                      'chat1',
                      save: (chat, id) async => saved.add('$chat=$id'),
                    );
                  },
                  child: const Text('open'),
                ),
                ChatThemeScope(
                  theme: ChatTheme.byId('grape'),
                  child: Builder(
                    builder: (c2) {
                      seen = ChatTheme.of(c2);
                      return const SizedBox();
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(seen?.id, 'grape');
      await t.tap(find.text('open'));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      for (final th in ChatTheme.all) {
        expect(find.byKey(ValueKey('chat-theme-${th.id}')), findsOneWidget);
      }
      await t.tap(find.byKey(const ValueKey('chat-theme-ocean')));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(saved, ['chat1=ocean']);
      expect(picked, 'ocean');
    });
  });

  // ------------------------------------------------------------ replies
  group('close replies', () {
    setUp(() => CommentTile.debugLiked = (id) => Stream.value(false));
    tearDown(() => CommentTile.debugLiked = null);

    testWidgets('arrow hides the replies, "View" opens them again', (t) async {
      final ctrl = StreamController<List<Comment>>();
      await t.pumpWidget(
        _app(CommentsSheet(post: _post(), stream: ctrl.stream, myUid: 'me')),
      );
      ctrl.add([
        _c('c1'),
        _c('r1', parent: 'c1'),
        _c('r2', parent: 'c1'),
        _c('r3', parent: 'c1'),
      ]);
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('comment-r1')), findsOneWidget);
      expect(find.byKey(const ValueKey('hide-replies-c1')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('more-replies-c1')));
      await t.pump();
      expect(find.byKey(const ValueKey('comment-r3')), findsOneWidget);
      // close (the list is short in tests: scroll to the arrow first)
      await t.ensureVisible(
        find.byKey(const ValueKey('hide-replies-c1'), skipOffstage: false),
      );
      await t.pump();
      await t.tap(find.byKey(const ValueKey('hide-replies-c1')));
      await t.pump();
      expect(find.byKey(const ValueKey('comment-r1')), findsNothing);
      expect(find.byKey(const ValueKey('comment-r3')), findsNothing);
      expect(find.byKey(const ValueKey('hide-replies-c1')), findsNothing);
      expect(find.text('View 3 replies'), findsOneWidget);
      expect(find.byKey(const ValueKey('comment-c1')), findsOneWidget);
      // open again
      await t.tap(find.byKey(const ValueKey('more-replies-c1')));
      await t.pump();
      expect(find.byKey(const ValueKey('comment-r1')), findsOneWidget);
      expect(find.byKey(const ValueKey('comment-r3')), findsOneWidget);
      await ctrl.close();
    });
  });

  // ------------------------------------------------------------ notices
  group('notice with a picture', () {
    tearDown(() => NoticePush.debugShow = null);

    test('data from the push', () {
      final n = NoticeData.from({
        'type': 'notice',
        'title': ' Hello ',
        'body': 'New features!',
        'image': 'https://cdn.test/p.jpg',
      })!;
      expect(n.title, 'Hello');
      expect(n.body, 'New features!');
      expect(n.image, 'https://cdn.test/p.jpg');
      // no text -> nothing; no title -> app name; http picture -> ignored
      expect(NoticeData.from({'title': 'x', 'body': ' '}), isNull);
      final m = NoticeData.from({'body': 'b', 'image': 'http://x/p.jpg'})!;
      expect(m.title, 'InstantGram');
      expect(m.image, '');
      // texts from the notification part win
      final o = NoticeData.from({'body': 'b'}, title: 'T', body: 'B')!;
      expect([o.title, o.body], ['T', 'B']);
    });

    test('picture download: only real https pictures', () async {
      final png = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);
      final hits = <String>[];
      final client = MockClient((r) async {
        hits.add(r.url.path);
        switch (r.url.path) {
          case '/ok.png':
            return http.Response.bytes(
              png,
              200,
              headers: {'content-type': 'image/png'},
            );
          case '/page':
            return http.Response(
              '<html>',
              200,
              headers: {'content-type': 'text/html'},
            );
          case '/big':
            return http.Response.bytes(
              Uint8List(NoticePush.maxImageBytes + 1),
              200,
              headers: {'content-type': 'image/jpeg'},
            );
          default:
            return http.Response('', 404);
        }
      });
      Future<Uint8List?> get(String u) =>
          NoticePush.downloadImage(u, client: client);
      expect(await get('https://x.test/ok.png'), png);
      expect(await get('https://x.test/page'), isNull);
      expect(await get('https://x.test/big'), isNull);
      expect(await get('https://x.test/missing'), isNull);
      expect(await get('http://x.test/ok.png'), isNull);
      expect(await get('not a url'), isNull);
      expect(hits, ['/ok.png', '/page', '/big', '/missing']);
      // a broken connection -> no picture, no crash
      final broken = MockClient((r) async => throw const SocketLike());
      expect(
        await NoticePush.downloadImage('https://x/p.png', client: broken),
        isNull,
      );
    });

    test('show(): downloads the picture and shows it', () async {
      final shown = <(NoticeData, Uint8List?)>[];
      NoticePush.debugShow = (n, img) async => shown.add((n, img));
      final pic = Uint8List.fromList([1, 2, 3]);
      final asked = <String>[];
      await NoticePush.show(
        {
          'type': 'notice',
          'title': 'Hi',
          'body': 'Look',
          'image': 'https://x/p.jpg',
        },
        download: (u) async {
          asked.add(u);
          return pic;
        },
      );
      // picture failed -> still shows the text
      await NoticePush.show({
        'body': 'Text only',
        'image': 'https://x/broken.jpg',
      }, download: (u) async => null);
      // no picture -> no download
      await NoticePush.show({
        'body': 'Plain',
      }, download: (u) async => throw StateError('no'));
      // no text -> nothing
      await NoticePush.show({'title': 'x'});
      expect(asked, ['https://x/p.jpg']);
      expect(shown.map((s) => s.$1.body), ['Look', 'Text only', 'Plain']);
      expect(shown[0].$2, pic);
      expect(shown[1].$2, isNull);
      expect(shown[2].$2, isNull);
    });
  });
}

class SocketLike implements Exception {
  const SocketLike();
}
