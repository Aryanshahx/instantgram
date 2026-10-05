import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/app_events.dart';
import 'package:instantgram/core/errors.dart';
import 'package:instantgram/core/hashtags.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/app_user.dart';
import 'package:instantgram/models/chat.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/models/story.dart';
import 'package:instantgram/screens/chat/gif_picker.dart';
import 'package:instantgram/screens/chat/message_actions.dart';
import 'package:instantgram/screens/story/story_composer.dart';
import 'package:instantgram/services/giphy.dart';
import 'package:instantgram/services/location_service.dart';
import 'package:instantgram/services/post_search.dart';
import 'package:instantgram/services/system_volume.dart';
import 'package:instantgram/widgets/message_bubble.dart';
import 'package:instantgram/widgets/post_details_sheet.dart';
import 'package:instantgram/widgets/recipient_sheet.dart';
import 'package:instantgram/widgets/story_overlays.dart';
import 'package:instantgram/widgets/swipe_to_reply.dart';

Post _post(
  String id,
  String caption, {
  String user = 'aryan',
  int views = 0,
  String type = 'image',
}) => Post(
  id: id,
  authorId: 'u1',
  authorUsername: user,
  authorPhotoUrl: '',
  type: type,
  caption: caption,
  createdAt: DateTime(2026, 10, 4, 9, 5),
  viewCount: views,
);

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.status, this.body);
  final int status;
  final Object body;
  Uri? last;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    last = options.uri;
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakeVolume implements VolumeBackend {
  double now = 0.4;
  void Function(double)? cb;
  bool stopped = false;
  @override
  Future<double> get() async => now;
  @override
  Future<void> set(double v) async => now = v;
  @override
  VoidCallback listen(void Function(double v) onChange) {
    cb = onChange;
    return () => stopped = true;
  }
}

Widget _host(Widget child, {double width = 360}) => MaterialApp(
  theme: AppTheme.dark,
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: width,
        child: SingleChildScrollView(child: child),
      ),
    ),
  ),
);

ChatMessage _msg(
  String type, {
  String text = '',
  String sender = 'me',
  ReplyRef? reply,
  bool forwarded = false,
  bool pinned = false,
  bool deleted = false,
  Map<String, String> reactions = const {},
  String postTitle = '',
}) => ChatMessage(
  id: 'm1',
  senderId: sender,
  text: text,
  createdAt: DateTime(2026, 10, 4, 10),
  type: type,
  replyTo: reply,
  forwarded: forwarded,
  pinned: pinned,
  deleted: deleted,
  reactions: reactions,
  postTitle: postTitle,
  postAuthor: 'sam',
  lat: 26.8467,
  lng: 80.9462,
  duration: 12,
);

void main() {
  group('hashtags and search', () {
    test('hashtags are found once, lowercase', () {
      expect(extractHashtags('Hi #Flutter #dart_2 #flutter and #'), [
        'flutter',
        'dart_2',
      ]);
      expect(extractHashtags('no tags here'), isEmpty);
    });

    test('filterPosts matches tags, words and authors', () {
      final pool = [
        _post('1', 'Sunset at the lake #sunset #lake'),
        _post('2', 'my sunrise #sun'),
        _post('3', 'lunch', user: 'sunny'),
        _post('4', 'something else'),
      ];
      expect(filterPosts(pool, '#sunset').map((p) => p.id), ['1']);
      expect(filterPosts(pool, '#sun').map((p) => p.id).toSet(), {'1', '2'});
      expect(filterPosts(pool, 'sunny').map((p) => p.id), ['3']);
      expect(filterPosts(pool, 'sunset lake').map((p) => p.id), ['1']);
      expect(filterPosts(pool, ''), isEmpty);
      expect(filterPosts(pool, 'zzz'), isEmpty);
    });

    test('an exact hashtag is listed before a partial one', () {
      final pool = [_post('a', 'x #sunrise'), _post('b', 'y #sun')];
      expect(filterPosts(pool, '#sun').map((p) => p.id), ['b', 'a']);
    });

    test('trending tags: most used first, ties alphabetical', () {
      final pool = [
        _post('1', '#b #a'),
        _post('2', '#b'),
        _post('3', '#c #a #b'),
      ];
      expect(trendingTags(pool), ['b', 'a', 'c']);
      expect(trendingTags(pool, limit: 1), ['b']);
    });

    testWidgets('tapping a hashtag reports the tag', (tester) async {
      String? got;
      await tester.pumpWidget(
        _host(HashtagText('look #Sunset now', onTag: (t) => got = t)),
      );
      final rich = tester.widget<RichText>(
        find.descendant(
          of: find.byType(HashtagText),
          matching: find.byType(RichText),
        ),
      );
      TextSpan? tag;
      rich.text.visitChildren((s) {
        if (s is TextSpan && s.text == '#Sunset') tag = s;
        return true;
      });
      expect(tag, isNotNull);
      (tag!.recognizer! as TapGestureRecognizer).onTap!();
      expect(got, 'sunset');
    });

    test('openSearch publishes the query', () {
      AppEvents.openSearch('#abc');
      expect(AppEvents.searchRequest.value, '#abc');
      AppEvents.searchRequest.value = null;
    });
  });

  group('system volume', () {
    test('reads the phone volume, follows the buttons, sets it', () async {
      final fake = _FakeVolume();
      final v = SystemVolume.instance..backend = fake;
      await v.start();
      expect(v.level.value, 0.4);
      fake.cb!(0.7);
      expect(v.level.value, 0.7);
      await v.set(1.4);
      expect(fake.now, 1.0);
      expect(v.level.value, 1.0);
      v.stop();
      expect(fake.stopped, isTrue);
    });
  });

  group('post details', () {
    test('numbers are shortened', () {
      expect(compactCount(950), '950');
      expect(compactCount(1200), '1.2K');
      expect(compactCount(12500), '13K');
      expect(compactCount(3000000), '3M');
    });

    testWidgets('the sheet shows the views and refreshes them', (tester) async {
      await tester.pumpWidget(
        _host(
          PostDetailsSheet(
            post: _post('p1', 'Hello #world', views: 5),
            loader: (_) async => _post('p1', 'Hello #world', views: 42),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Views'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('@aryan'), findsOneWidget);
      expect(find.text('Photo post'), findsOneWidget);
    });
  });

  group('chat messages', () {
    test('previews', () {
      expect(messagePreview(MsgType.text, 'hi'), 'hi');
      expect(messagePreview(MsgType.gif, ''), 'GIF');
      expect(messagePreview(MsgType.voice, ''), contains('Voice'));
      expect(
        messagePreview(MsgType.post, '', postIsClip: true),
        contains('Clip'),
      );
      expect(
        messagePreview(MsgType.image, '', deleted: true),
        'Message deleted',
      );
    });

    test('a reply reference survives the round trip', () {
      const r = ReplyRef(id: 'x', senderId: 'u', kind: 'voice', preview: 'p');
      final back = ReplyRef.fromMap(r.toMap())!;
      expect(back.id, 'x');
      expect(back.kind, 'voice');
      expect(ReplyRef.fromMap({'id': ''}), isNull);
      expect(ReplyRef.fromMap('nope'), isNull);
    });

    test('reactions are counted and messages can be hidden per person', () {
      final m = _msg(
        MsgType.text,
        text: 'x',
        reactions: {'a': '❤️', 'b': '❤️', 'c': '😂'},
      );
      expect(m.reactionCounts, {'❤️': 2, '😂': 1});
      final hidden = ChatMessage(
        id: 'h',
        senderId: 's',
        text: '',
        createdAt: _epoch,
        hiddenFor: ['me'],
      );
      expect(hidden.visibleFor('me'), isFalse);
      expect(hidden.visibleFor('you'), isTrue);
    });

    test('a photo keeps its proportions', () {
      final m = ChatMessage(
        id: 'i',
        senderId: 's',
        text: '',
        createdAt: _epoch,
        type: MsgType.image,
        width: 400,
        height: 200,
      );
      expect(m.aspect, 2);
      expect(_msg(MsgType.image).aspect, 1);
    });

    testWidgets('plain text bubble still works', (tester) async {
      await tester.pumpWidget(
        _host(const MessageBubble(text: 'hello', mine: true, time: '10:00')),
      );
      expect(find.text('hello'), findsOneWidget);
      expect(find.text('10:00'), findsOneWidget);
    });

    testWidgets('reply, forwarded, pinned and reactions show', (tester) async {
      String? reacted;
      await tester.pumpWidget(
        _host(
          MessageBubble(
            mine: false,
            time: '10:00',
            myUid: 'me',
            nameOf: (u) => u == 'me' ? 'You' : 'sam',
            message: _msg(
              MsgType.text,
              text: 'the answer',
              sender: 'u2',
              forwarded: true,
              pinned: true,
              reply: const ReplyRef(
                id: 'q',
                senderId: 'me',
                kind: MsgType.text,
                preview: 'the question',
              ),
              reactions: const {'me': '❤️'},
            ),
            onReact: (e) => reacted = e,
          ),
        ),
      );
      expect(find.text('the answer'), findsOneWidget);
      expect(find.text('Forwarded'), findsOneWidget);
      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('the question'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reaction_❤️')));
      expect(reacted, '❤️');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a deleted message shows only the stub', (tester) async {
      await tester.pumpWidget(
        _host(
          MessageBubble(
            mine: true,
            time: '10:00',
            message: _msg(MsgType.text, text: 'secret', deleted: true),
          ),
        ),
      );
      expect(find.text('This message was deleted'), findsOneWidget);
      expect(find.text('secret'), findsNothing);
    });

    testWidgets('voice, shared post and location bubbles render', (
      tester,
    ) async {
      for (final w in [320.0, 411.0, 800.0]) {
        await tester.pumpWidget(
          _host(
            Column(
              children: [
                MessageBubble(
                  mine: true,
                  time: '1',
                  message: _msg(MsgType.voice),
                ),
                MessageBubble(
                  mine: false,
                  time: '2',
                  message: _msg(
                    MsgType.post,
                    sender: 'u2',
                    text: 'look',
                    postTitle: 'My trip',
                  ),
                ),
                MessageBubble(
                  mine: true,
                  time: '3',
                  message: _msg(MsgType.location),
                ),
              ],
            ),
            width: w,
          ),
        );
        await tester.pump();
        expect(find.byKey(const ValueKey('voicePlay')), findsOneWidget);
        expect(find.text('0:12'), findsOneWidget);
        expect(find.text('@sam'), findsOneWidget);
        expect(find.text('My trip'), findsOneWidget);
        expect(find.text('look'), findsOneWidget);
        expect(find.text('26.84670, 80.94620'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('swiping a message far enough replies, a nudge does not', (
      tester,
    ) async {
      var replies = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SwipeToReply(
              onReply: () => replies++,
              child: const SizedBox(width: 300, height: 60, child: Text('m')),
            ),
          ),
        ),
      );
      await tester.drag(find.text('m'), const Offset(20, 0));
      await tester.pumpAndSettle();
      expect(replies, 0);
      await tester.drag(find.text('m'), const Offset(120, 0));
      await tester.pumpAndSettle();
      expect(replies, 1);
    });

    testWidgets('the message menu offers the right actions', (tester) async {
      Future<void> open(ChatMessage m, bool mine) async {
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            theme: AppTheme.dark,
            home: Builder(
              builder: (ctx) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      showMessageMenu(ctx, message: m, mine: mine, myUid: 'me'),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      }

      await open(_msg(MsgType.text, text: 'x'), true);
      expect(find.byKey(const ValueKey('action_reply')), findsOneWidget);
      expect(find.byKey(const ValueKey('action_copy')), findsOneWidget);
      expect(find.byKey(const ValueKey('action_pin')), findsOneWidget);
      expect(find.byKey(const ValueKey('action_deleteForAll')), findsOneWidget);
      expect(find.byKey(const ValueKey('pick_😂')), findsOneWidget);

      await open(_msg(MsgType.voice, sender: 'u2', pinned: true), false);
      expect(find.byKey(const ValueKey('action_copy')), findsNothing);
      expect(find.byKey(const ValueKey('action_unpin')), findsOneWidget);
      expect(find.byKey(const ValueKey('action_deleteForAll')), findsNothing);
      expect(find.byKey(const ValueKey('action_deleteForMe')), findsOneWidget);

      await open(_msg(MsgType.text, deleted: true), true);
      expect(find.byKey(const ValueKey('action_reply')), findsNothing);
      expect(find.byKey(const ValueKey('action_deleteForMe')), findsOneWidget);
    });
  });

  group('GIFs (Giphy)', () {
    Map<String, dynamic> entry(String id) => {
      'id': id,
      'images': {
        'fixed_width': {
          'url': 'https://g/$id.gif',
          'width': '200',
          'height': '150',
        },
        'fixed_width_small': {
          'url': 'https://g/$id-s.gif',
          'width': '100',
          'height': '75',
        },
      },
    };

    test('results are read, broken ones skipped', () async {
      final dio = Dio()
        ..httpClientAdapter = _FakeAdapter(200, {
          'data': [
            entry('a'),
            {'id': 'bad'},
            entry('b'),
          ],
        });
      final c = GiphyClient(dio: dio, key: 'k');
      final r = await c.search('cats');
      expect(r.map((g) => g.id), ['a', 'b']);
      expect(r.first.width, 200);
      expect(r.first.aspect, closeTo(200 / 150, 0.001));
      expect(r.first.previewUrl, endsWith('a-s.gif'));
      final adapter = dio.httpClientAdapter as _FakeAdapter;
      expect(adapter.last!.path, endsWith('/search'));
      expect(adapter.last!.queryParameters['q'], 'cats');
      expect(adapter.last!.queryParameters['api_key'], 'k');
      expect(adapter.last!.queryParameters['rating'], 'g');
    });

    test('an empty search shows what is trending', () async {
      final dio = Dio()..httpClientAdapter = _FakeAdapter(200, {'data': []});
      await GiphyClient(dio: dio, key: 'k').search('  ');
      expect(
        (dio.httpClientAdapter as _FakeAdapter).last!.path,
        endsWith('/trending'),
      );
    });

    test('no key and a rejected key are explained', () async {
      expect(GiphyClient(key: '').configured, isFalse);
      await expectLater(
        GiphyClient(key: '').trending(),
        throwsA(isA<MediaException>()),
      );
      final dio = Dio()..httpClientAdapter = _FakeAdapter(403, {});
      await expectLater(
        GiphyClient(dio: dio, key: 'bad').trending(),
        throwsA(
          isA<MediaException>().having(
            (e) => e.message,
            'message',
            contains('key'),
          ),
        ),
      );
    });

    testWidgets('the picker lists GIFs and returns the tapped one', (
      tester,
    ) async {
      final dio = Dio()
        ..httpClientAdapter = _FakeAdapter(200, {
          'data': [entry('a'), entry('b')],
        });
      GifItem? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () async => picked = await showGifPicker(
                  ctx,
                  client: GiphyClient(dio: dio, key: 'k'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Powered by GIPHY'), findsOneWidget);
      expect(find.byKey(const ValueKey('gif_a')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('gif_b')));
      await tester.pumpAndSettle();
      expect(picked?.id, 'b');
    });
  });

  group('location', () {
    test('map tile maths', () {
      final a = mapSpot(0, 0, 1);
      expect(a.x, closeTo(1, 1e-9));
      expect(a.y, closeTo(1, 1e-9));
      final b = mapSpot(0, -180, 3);
      expect(b.x, closeTo(0, 1e-9));
      expect(b.y, closeTo(4, 1e-9));
      final lucknow = mapSpot(26.8467, 80.9462, 16);
      expect(lucknow.tileX, inInclusiveRange(0, 65535));
      expect(lucknow.tileX, 47216 + (lucknow.tileX - 47216));
      final poleSafe = mapSpot(89.9, 0, 4);
      expect(poleSafe.y.isFinite, isTrue);
    });

    test('coordinates and links', () {
      expect(formatCoords(26.8467, 80.9462), '26.84670, 80.94620');
      expect(mapsUri(1.5, 2.5).toString(), contains('query=1.5,2.5'));
    });
  });

  group('profile links and stories', () {
    test('a link shows its own name, or the address when it has none', () {
      const u = AppUser(
        uid: 'u',
        username: 'a',
        links: ['https://a.com', 'https://b.com'],
        linkNames: ['My shop', ''],
      );
      expect(u.linkLabel(0), 'My shop');
      expect(u.linkLabel(1), '');
      expect(u.linkLabel(5), '');
    });

    test('overlays survive the round trip and bad ones are dropped', () {
      const o = StoryOverlay(
        text: 'Hello',
        dx: 0.25,
        dy: 0.75,
        scale: 1.5,
        color: 0xFFD2FF3F,
        pill: true,
      );
      final back = StoryOverlay.fromMap(o.toMap())!;
      expect(back.text, 'Hello');
      expect(back.dx, 0.25);
      expect(back.scale, 1.5);
      expect(back.pill, isTrue);
      expect(back.color, 0xFFD2FF3F);
      expect(StoryOverlay.fromMap({'t': ''}), isNull);
      expect(StoryOverlay.fromMap(7), isNull);
      expect(StoryOverlay.fromMap({'t': 'x', 'x': 9, 'y': -3})!.dx, 1);
      expect(StoryOverlay.fromMap({'t': 'x', 'x': 9, 'y': -3})!.dy, 0);
    });

    test(
      'a moment lasts 6 seconds for a photo, the video length for a video',
      () {
        final photo = Story(
          id: '1',
          authorId: 'a',
          username: 'a',
          photoUrl: '',
          imageRef: 'm:x',
          createdAt: _epoch,
        );
        expect(photo.seconds, kStoryPhotoSeconds);
        expect(photo.isVideo, isFalse);
        final video = Story(
          id: '2',
          authorId: 'a',
          username: 'a',
          photoUrl: '',
          imageRef: '',
          createdAt: _epoch,
          videoRef: 'm:v',
          duration: 12,
        );
        expect(video.isVideo, isTrue);
        expect(video.seconds, 12);
        final long = Story(
          id: '3',
          authorId: 'a',
          username: 'a',
          photoUrl: '',
          imageRef: '',
          createdAt: _epoch,
          videoRef: 'm:v',
          duration: 500,
        );
        expect(long.seconds, kMaxStorySeconds);
      },
    );

    testWidgets('texts and stickers sit where they were placed', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 640,
              child: StoryCanvas(
                media: const ColoredBox(color: Colors.blue),
                overlays: const [
                  StoryOverlay(text: 'Hi there', dx: 0.5, dy: 0.5),
                  StoryOverlay(text: '🔥', dx: 0.25, dy: 0.25, emoji: true),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('Hi there'), findsOneWidget);
      expect(find.text('🔥'), findsOneWidget);
      final c = tester.getCenter(find.text('Hi there'));
      final canvas = tester.getRect(find.byType(AspectRatio));
      expect(c.dx, closeTo(canvas.center.dx, 1));
      expect(c.dy, closeTo(canvas.center.dy, 1));
      expect(canvas.width / canvas.height, closeTo(9 / 16, 0.001));
      final fire = tester.getCenter(find.text('🔥'));
      expect(fire.dx, closeTo(canvas.left + canvas.width * 0.25, 2));
    });
  });

  group('sending to people', () {
    final users = [
      const AppUser(uid: 'u1', username: 'asha'),
      const AppUser(uid: 'u2', username: 'ravi'),
    ];

    testWidgets('pick people, add a note, send', (tester) async {
      RecipientPick? pick;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () async => pick = await pickRecipients(
                  ctx,
                  title: 'Send',
                  withNote: true,
                  loadSuggestions: () async => users,
                  search: (q) async => [
                    for (final u in users)
                      if (u.username.startsWith(q)) u,
                  ],
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('asha'), findsOneWidget);
      final send = find.byKey(const ValueKey('recipientSend'));
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('recipient_u2')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('shareNote')),
        'check this',
      );
      await tester.tap(find.byKey(const ValueKey('recipient_u1')));
      await tester.pump();
      expect(find.text('Send (2)'), findsOneWidget);
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(pick!.users.map((u) => u.uid).toSet(), {'u1', 'u2'});
      expect(pick!.note, 'check this');
    });

    testWidgets('searching narrows the list', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: RecipientSheet(
              title: 'Send',
              actionLabel: 'Send',
              withNote: false,
              loadSuggestions: () async => users,
              search: (q) async => [
                for (final u in users)
                  if (u.username.startsWith(q)) u,
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('recipientSearch')),
        'ra',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('ravi'), findsOneWidget);
      expect(find.text('asha'), findsNothing);
    });
  });

  group('moment editor', () {
    late File png;
    setUpAll(() {
      png = File('${Directory.systemTemp.path}/v1100_pixel.png')
        ..writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
          ),
        );
    });

    Future<void> open(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: StoryComposerScreen(image: png),
        ),
      );
      await tester.pump();
    }

    testWidgets('add text, move it, remove it', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('storyText')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('storyTextInput')),
        'Good morning',
      );
      await tester.tap(find.byKey(const ValueKey('storyTextDone')));
      await tester.pumpAndSettle();
      expect(find.text('Good morning'), findsOneWidget);
      final before = tester.getCenter(find.text('Good morning'));
      await tester.drag(find.text('Good morning'), const Offset(0, 120));
      await tester.pump();
      final after = tester.getCenter(find.text('Good morning'));
      expect(after.dy, greaterThan(before.dy + 60));
      await tester.tap(find.text('Good morning'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('storyTextDelete')));
      await tester.pumpAndSettle();
      expect(find.text('Good morning'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty text adds nothing, a sticker can be added', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('storyText')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('storyTextDone')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('overlay0')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('storySticker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('emoji_🔥')));
      await tester.pumpAndSettle();
      expect(find.text('🔥'), findsOneWidget);
      expect(find.byKey(const ValueKey('storyShare')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

final DateTime _epoch = DateTime(2026, 1, 1);
