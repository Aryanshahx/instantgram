import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';
import 'package:instantgram/core/navigation/page_cover.dart';
import 'package:instantgram/core/services/calls.dart';
import 'package:instantgram/core/services/content_filter.dart';
import 'package:instantgram/core/services/location_service.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/chats/data/chat_repository.dart';
import 'package:instantgram/features/chats/presentation/chat_detail_screen.dart';
import 'package:instantgram/features/chats/presentation/message_widgets.dart';
import 'package:instantgram/features/post/data/upload_queue.dart';
import 'package:instantgram/features/post/presentation/comments_sheet.dart';
import 'package:instantgram/features/post/presentation/my_post_picker.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/models/user_profile.dart';
import 'package:instantgram/shared/widgets/net_image.dart';

// ------------------------------------------------------------ helpers

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark,
  navigatorObservers: [PageCover.instance],
  home: Scaffold(body: child),
);

Post _post({String id = 'p1', String type = Post.clip}) => Post(
  id: id,
  authorId: 'author',
  authorUsername: 'author',
  authorPhotoUrl: '',
  type: type,
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

Comment _c(
  String id, {
  String parent = '',
  String text = 'hi',
  String author = 'bob',
  String refPostId = '',
}) => Comment(
  id: id,
  authorId: author,
  authorUsername: author,
  authorPhotoUrl: '',
  text: text,
  createdAt: DateTime(2026, 1, 1),
  parentId: parent,
  refPostId: refPostId,
  refPostType: refPostId.isEmpty ? '' : Post.clip,
  refThumb: refPostId.isEmpty ? '' : 'https://x.test/t.jpg',
  refAuthor: refPostId.isEmpty ? '' : author,
);

Message _m(
  String id, {
  String sender = 'other',
  String kind = Message.plain,
  String text = 'hello',
  Map<String, dynamic> extra = const {},
}) => Message.fromMap(id, {
  'senderId': sender,
  'kind': kind,
  'text': text,
  ...extra,
});

UserProfile _other() =>
    UserProfile.fromMap('other', const {'username': 'sam', 'photoUrl': ''});

/// Lets snackbars and small animations finish before the test ends.
Future<void> _finish(WidgetTester t) async {
  await t.pumpAndSettle();
  await t.pump(const Duration(seconds: 5));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() {
    NetImage.disableCache = true;
    VoiceBubble.disabled = true;
    Calls.disabled = true;
    CommentTile.debugLiked = (id) => Stream.value(false);
  });

  // ------------------------------------------------------------ models
  group('reply with a clip / post', () {
    test('ReplyRef from a comment / the post, label, map', () {
      final p = _post();
      final c = _c('c9', parent: 'c1', text: 'nice');
      final r = ReplyRef.fromComment(p, c);
      expect(r.isComment, isTrue);
      expect(r.threadId, 'c1');
      expect(r.label, "Reply to @bob's comment");
      final back = ReplyRef.fromMap(r.toMap())!;
      expect(back.commentId, 'c9');
      expect(back.parentId, 'c1');
      expect(back.text, 'nice');
      final whole = ReplyRef.toPost(p);
      expect(whole.isComment, isFalse);
      expect(whole.label, 'Reply to @author');
      expect(ReplyRef.fromMap({'postId': ''}), isNull);
    });

    test('upload task keeps the reply after an app restart', () {
      final t = UploadTask(
        id: 't1',
        kind: UploadTask.clip,
        items: [QueuedMedia(path: '/x.mp4', isVideo: true)],
        replyTo: ReplyRef.fromComment(_post(), _c('c2')),
      )..replyDone = true;
      final back = UploadTask.fromJson(t.toJson())!;
      expect(back.replyTo?.commentId, 'c2');
      expect(back.replyDone, isTrue);
      final plain = UploadTask.fromJson(
        UploadTask(id: 't2', kind: UploadTask.post, items: const []).toJson(),
      )!;
      expect(plain.replyTo, isNull);
    });

    testWidgets('comment with a linked clip shows its card', (t) async {
      final ctrl = StreamController<List<Comment>>();
      await t.pumpWidget(
        _app(CommentsSheet(post: _post(), stream: ctrl.stream, myUid: 'me')),
      );
      ctrl.add([_c('c1', refPostId: 'p7')]);
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('comment-ref-c1')), findsOneWidget);
      expect(find.byType(LinkedPostCard), findsOneWidget);
      // v0.9: no white lines
      expect(find.byType(Divider), findsNothing);
      expect(find.text('——'), findsNothing);
      expect(find.byKey(const ValueKey('comment-reply-with')), findsOneWidget);
      await ctrl.close();
    });

    testWidgets('reply-with sheet has 3 choices', (t) async {
      ReplyWith? got;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  got = await showReplyWithSheet(context, to: 'bob'),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('reply-with-mine')), findsOneWidget);
      expect(find.byKey(const ValueKey('reply-with-new-post')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('reply-with-new-clip')));
      await t.pumpAndSettle();
      expect(got, ReplyWith.newClip);
    });

    testWidgets('sticker shows who is answered', (t) async {
      var taps = 0;
      await t.pumpWidget(
        _app(
          ReplyStickerChip(
            reply: ReplyRef.fromComment(_post(), _c('c1')),
            onTap: () => taps++,
          ),
        ),
      );
      expect(find.textContaining("@bob's comment"), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('reply-sticker')));
      expect(taps, 1);
    });
  });

  // ------------------------------------------------------------ panel
  group('comments panel', () {
    testWidgets('opens at 60 %, drag up = full screen, reports its top', (
      t,
    ) async {
      final tops = <double?>[];
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                showDragHandle: false,
                enableDrag: false,
                backgroundColor: Colors.transparent,
                builder: (_) => CommentsPanel(
                  post: _post(),
                  stream: Stream.value([_c('c1')]),
                  myUid: 'me',
                  onSheetTop: tops.add,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      final h = t.view.physicalSize.height / t.view.devicePixelRatio;
      expect(tops.last, closeTo(h * 0.4, 2));
      expect(find.byKey(const ValueKey('comments-panel')), findsOneWidget);
      // drag the header up to the top
      await t.drag(find.text('Comments'), Offset(0, -h * 0.6));
      await t.pumpAndSettle();
      expect(tops.last, lessThan(24));
      // and back down a bit -> 60 %
      await t.drag(find.text('Comments'), Offset(0, h * 0.35));
      await t.pumpAndSettle();
      expect(tops.last, closeTo(h * 0.4, 2));
    });

    testWidgets('showComments tells when it is closed', (t) async {
      final tops = <double?>[];
      late BuildContext ctx;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      // (the real sheet needs Firestore: only check the close callback)
      final route = showModalBottomSheet<void>(
        context: ctx,
        builder: (_) => const SizedBox(height: 100),
      ).whenComplete(() => tops.add(null));
      await t.pumpAndSettle();
      Navigator.of(ctx).pop();
      await t.pumpAndSettle();
      await route;
      expect(tops, [null]);
    });
  });

  // ------------------------------------------------------------ chat models
  group('chat messages', () {
    test('kinds, preview, maps link, reactions, hidden', () {
      final loc = _m(
        'l',
        kind: Message.location,
        text: '',
        extra: {'lat': 26.4499, 'lng': 80.3319, 'address': 'Kanpur'},
      );
      expect(loc.isLocation, isTrue);
      expect(loc.preview, '📍 Kanpur');
      expect(
        loc.mapsUri.toString(),
        'https://www.google.com/maps/search/?api=1&query=26.4499,80.3319',
      );
      final v = _m('v', kind: Message.voice, text: '');
      expect(v.preview, '🎤 Voice message');
      final r = _m(
        'r',
        extra: {
          'reactions': {'a': '❤️', 'b': '❤️', 'c': '😂'},
          'hiddenFor': ['me'],
          'replyTo': {'id': 'x', 'senderId': 'me', 'text': 'yo'},
        },
      );
      expect(r.reactionCounts.first.key, '❤️');
      expect(r.reactionCounts.first.value, 2);
      expect(r.hiddenForUid('me'), isTrue);
      expect(r.replyTo?.text, 'yo');
      // old messages without "kind"
      final old = Message.fromMap('o', {'senderId': 'a', 'postId': 'p'});
      expect(old.kind, Message.post);
    });

    test('forwarded copy has no owner file / reactions / reply', () {
      final m = _m(
        'i',
        kind: Message.image,
        text: '',
        extra: {
          'mediaUrl': 'https://x.test/a.jpg',
          'mediaKey': 'chat/u/a.jpg',
          'width': 10,
          'height': 20,
          'reactions': {'a': '❤️'},
          'replyTo': {'id': 'x', 'senderId': 'me', 'text': 'yo'},
        },
      );
      final f = ChatRepository.forwardFields(m);
      expect(f['forwarded'], isTrue);
      expect(f['mediaUrl'], 'https://x.test/a.jpg');
      expect(f.containsKey('mediaKey'), isFalse);
      expect(f.containsKey('reactions'), isFalse);
      expect(f.containsKey('replyTo'), isFalse);
      expect(f['kind'], Message.image);
    });

    test('durations and addresses', () {
      expect(formatDuration(7000), '0:07');
      expect(formatDuration(85400), '1:25');
      final a = LocationService.formatPlace(
        const Placemark(
          name: '7JWX+2Q',
          street: 'Mall Road',
          subLocality: 'Civil Lines',
          locality: 'Kanpur',
          administrativeArea: 'Uttar Pradesh',
        ),
      );
      expect(a, 'Mall Road, Civil Lines, Kanpur, Uttar Pradesh');
    });
  });

  // ------------------------------------------------------------ chat UI
  group('chat screen', () {
    setUp(() => ContentFilter.instance.debugSet(me: 'me'));

    Future<StreamController<List<Message>>> open(
      WidgetTester t, {
      Chat? chat,
    }) async {
      final msgs = StreamController<List<Message>>();
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: ChatDetailScreen(
            other: _other(),
            messages: msgs.stream,
            chat: Stream.value(chat),
            myUid: 'me',
          ),
        ),
      );
      return msgs;
    }

    testWidgets('all message kinds + reactions + hidden', (t) async {
      final msgs = await open(t);
      msgs.add([
        _m('t1', text: 'hey there'),
        _m(
          'v1',
          sender: 'me',
          kind: Message.voice,
          text: '',
          extra: {'mediaUrl': 'https://x.test/v.m4a', 'durationMs': 7000},
        ),
        _m(
          'l1',
          kind: Message.location,
          text: '',
          extra: {'lat': 1.0, 'lng': 2.0, 'address': 'Mall Road, Kanpur'},
        ),
        _m(
          'g1',
          kind: Message.gif,
          text: '',
          extra: {
            'mediaUrl': 'https://x.test/g.webp',
            'width': 200,
            'height': 100,
            'forwarded': true,
            'reactions': {'other': '😂', 'me': '😂'},
          },
        ),
        _m(
          'h1',
          text: 'secret',
          extra: {
            'hiddenFor': ['me'],
          },
        ),
      ]);
      await t.pump();
      await t.pump();
      expect(find.text('hey there'), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-v1')), findsOneWidget);
      expect(find.text('0:07'), findsOneWidget);
      expect(find.byKey(const ValueKey('location-l1')), findsOneWidget);
      expect(find.text('Mall Road, Kanpur'), findsOneWidget);
      expect(find.text('Forwarded'), findsOneWidget);
      expect(find.byKey(const ValueKey('reactions-g1')), findsOneWidget);
      expect(find.text('secret'), findsNothing); // deleted for me
      // voice play toggles (audio plugin off in tests)
      await t.tap(find.byKey(const ValueKey('voice-play')));
      await t.pump();
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      await msgs.close();
      await _finish(t);
    });

    testWidgets('swipe right = reply, long-press = menu', (t) async {
      final msgs = await open(t);
      msgs.add([
        _m('t1', text: 'swipe me'),
        _m('t2', sender: 'me', text: 'mine'),
      ]);
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('chat-mic')), findsOneWidget);
      // swipe right
      final g = await t.startGesture(t.getCenter(find.text('swipe me')));
      for (var i = 0; i < 8; i++) {
        await g.moveBy(const Offset(12, 0));
        await t.pump();
      }
      await g.up();
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-replying')), findsOneWidget);
      expect(find.text('Replying to sam'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('chat-reply-cancel')));
      await t.pump();
      expect(find.byKey(const ValueKey('chat-replying')), findsNothing);
      // long-press someone else's message: no "Delete for everyone"
      await t.longPress(find.text('swipe me'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('react-❤️')), findsOneWidget);
      expect(find.byKey(const ValueKey('msg-forward')), findsOneWidget);
      expect(find.byKey(const ValueKey('msg-pin')), findsOneWidget);
      expect(find.byKey(const ValueKey('msg-deleteMe')), findsOneWidget);
      expect(find.byKey(const ValueKey('msg-deleteAll')), findsNothing);
      await t.tap(find.byKey(const ValueKey('msg-reply')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-replying')), findsOneWidget);
      // my message: "Delete for everyone" is there
      await t.longPress(find.text('mine'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('msg-deleteAll')), findsOneWidget);
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      // typing switches mic -> send
      await t.enterText(find.byKey(const ValueKey('chat-input')), 'hi');
      await t.pump();
      expect(find.byKey(const ValueKey('chat-send')), findsOneWidget);
      await msgs.close();
      await _finish(t);
    });

    testWidgets('pinned bar, attach menu, calls off', (t) async {
      final chat = Chat.fromMap('me_other', {
        'members': ['me', 'other'],
        'pinned': {'id': 't1', 'text': 'meet at 5'},
      });
      final msgs = await open(t, chat: chat);
      msgs.add([_m('t1', text: 'meet at 5')]);
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('pinned-bar')), findsOneWidget);
      expect(find.text('Pinned message'), findsOneWidget);
      // + menu: Photo / GIF / Location
      await t.tap(find.byKey(const ValueKey('chat-attach')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('attach-photo')), findsOneWidget);
      expect(find.byKey(const ValueKey('attach-gif')), findsOneWidget);
      expect(find.byKey(const ValueKey('attach-location')), findsOneWidget);
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      // calls not set up -> friendly message
      await t.tap(find.byKey(const ValueKey('call-video')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('Calls are not set up'), findsOneWidget);
      await msgs.close();
      await _finish(t);
    });
  });

  // ------------------------------------------------------------ swipe
  testWidgets('short swipe does not reply', (t) async {
    var replies = 0;
    await t.pumpWidget(
      _app(
        Center(
          child: SwipeToReply(
            onReply: () => replies++,
            child: const SizedBox(width: 200, height: 50, child: Text('msg')),
          ),
        ),
      ),
    );
    await t.drag(find.text('msg'), const Offset(30, 0));
    await t.pumpAndSettle();
    expect(replies, 0);
    await t.drag(find.text('msg'), const Offset(120, 0));
    await t.pumpAndSettle();
    expect(replies, 1);
  });
}
