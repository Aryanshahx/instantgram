import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/services/calls.dart';
import 'package:instantgram/core/services/content_filter.dart';
import 'package:instantgram/core/services/presence.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/calls/call_screen.dart';
import 'package:instantgram/features/calls/call_session.dart';
import 'package:instantgram/features/chats/data/chat_receipts.dart';
import 'package:instantgram/features/chats/presentation/chat_detail_screen.dart';
import 'package:instantgram/features/chats/presentation/message_widgets.dart';
import 'package:instantgram/features/post/presentation/comments_sheet.dart';
import 'package:instantgram/features/reels/presentation/clips_screen.dart';
import 'package:instantgram/features/settings/presentation/settings_pages.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/models/user_profile.dart';
import 'package:instantgram/shared/widgets/active_status.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

// v0.10: clips pause + buttons, comments "+", ticks, active status,
// reply jump, calls.

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark,
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

final _t0 = DateTime(2026, 10, 14, 12);
Timestamp _ts(int minutes) =>
    Timestamp.fromDate(_t0.add(Duration(minutes: minutes)));

Message _m(
  String id, {
  String sender = 'other',
  String text = 'hello',
  int at = 0,
  bool pending = false,
  Map<String, dynamic> extra = const {},
}) => Message.fromMap(id, {
  'senderId': sender,
  'text': text,
  'createdAt': _ts(at),
  ...extra,
}, pending: pending);

Chat _chat({
  Map<String, int> seen = const {},
  Map<String, int> delivered = const {},
  String last = 'me',
  int updated = 0,
}) => Chat.fromMap('me_other', {
  'members': ['me', 'other'],
  'lastSenderId': last,
  'lastMessage': 'x',
  'updatedAt': _ts(updated),
  'seen': {for (final e in seen.entries) e.key: _ts(e.value)},
  'delivered': {for (final e in delivered.entries) e.key: _ts(e.value)},
});

UserProfile _other() =>
    UserProfile.fromMap('other', const {'username': 'sam', 'photoUrl': ''});

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

  // ------------------------------------------------------------ clips
  group('clips: pause stays paused', () {
    testWidgets('a tap is a tap: hold-end code does not run', (t) async {
      var taps = 0, starts = 0, ends = 0;
      await t.pumpWidget(
        _app(
          ClipTapArea(
            onTap: () => taps++,
            onDoubleTap: () {},
            onHoldStart: (_) => starts++,
            onHoldEnd: () => ends++,
            child: const SizedBox.expand(),
          ),
        ),
      );
      await t.tap(find.byType(ClipTapArea));
      await t.pump(const Duration(milliseconds: 400)); // double-tap wait
      expect(taps, 1);
      // before v0.10 the long-press CANCEL ran the hold-end code on every
      // tap: it paused, then the tap saw "paused" and played again
      expect(ends, 0);
      expect(starts, 0);
      await _finish(t);
    });

    testWidgets('a real hold: start + end once', (t) async {
      var taps = 0, starts = 0, ends = 0;
      await t.pumpWidget(
        _app(
          ClipTapArea(
            onTap: () => taps++,
            onHoldStart: (_) => starts++,
            onHoldEnd: () => ends++,
            child: const SizedBox.expand(),
          ),
        ),
      );
      await t.longPress(find.byType(ClipTapArea));
      await t.pump(const Duration(milliseconds: 400));
      expect(starts, 1);
      expect(ends, 1);
      expect(taps, 0);
      await _finish(t);
    });
  });

  group('clips: buttons come back after comments', () {
    testWidgets('panel says null LAST, after its close slide', (t) async {
      final tops = <double?>[];
      late BuildContext ctx;
      final comments = StreamController<List<Comment>>.broadcast();
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
      showModalBottomSheet<void>(
        context: ctx,
        isScrollControlled: true,
        useSafeArea: false,
        showDragHandle: false,
        enableDrag: false,
        backgroundColor: Colors.transparent,
        builder: (_) => CommentsPanel(
          post: _post(),
          onSheetTop: tops.add,
          stream: comments.stream,
          myUid: 'me',
        ),
      );
      await t.pump();
      comments.add(const []);
      await t.pumpAndSettle();
      expect(tops.whereType<double>(), isNotEmpty);
      expect(tops.last, isNotNull); // open: video small above the panel
      Navigator.of(ctx).pop();
      for (var i = 0; i < 40; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      await t.pumpAndSettle();
      // closed: the very last report is null (= full clip with buttons)
      expect(tops.last, isNull);
      expect(tops.where((v) => v == null).length, 1);
      await comments.close();
      await _finish(t);
    });
  });

  group('comments "+" button', () {
    testWidgets('one + with photo, GIF, my post, new clip, new post', (
      t,
    ) async {
      final ctrl = StreamController<List<Comment>>();
      await t.pumpWidget(
        _app(CommentsSheet(post: _post(), stream: ctrl.stream, myUid: 'me')),
      );
      ctrl.add(const []);
      await t.pump();
      expect(find.byKey(const ValueKey('comment-plus')), findsOneWidget);
      expect(find.byKey(const ValueKey('comment-gif')), findsNothing);
      expect(find.byKey(const ValueKey('comment-reply-with')), findsNothing);
      await t.tap(find.byKey(const ValueKey('comment-plus')));
      await t.pumpAndSettle();
      for (final id in ['photo', 'gif', 'mine', 'new-clip', 'new-post']) {
        expect(
          find.byKey(ValueKey('comment-attach-$id')),
          findsOneWidget,
          reason: id,
        );
      }
      await t.tapAt(const Offset(10, 10)); // close
      await t.pumpAndSettle();
      await ctrl.close();
      await _finish(t);
    });
  });

  // ------------------------------------------------------------ ticks
  group('ticks', () {
    test('chat model: seen / delivered / unread', () {
      final c = _chat(
        seen: {'other': 5},
        delivered: {'other': 3, 'me': 9},
        last: 'other',
        updated: 10,
      );
      expect(c.seenAt('other'), _t0.add(const Duration(minutes: 5)));
      // seen later than delivered counts as delivered
      expect(c.deliveredAt('other'), _t0.add(const Duration(minutes: 5)));
      expect(c.unreadFor('me'), isTrue); // never seen by me
      expect(c.unreadFor('other'), isFalse); // own message
      final read = _chat(seen: {'me': 11}, last: 'other', updated: 10);
      expect(read.unreadFor('me'), isFalse);
    });

    testWidgets('clock, ✓, ✓✓ and green ✓✓ on my messages', (t) async {
      ContentFilter.instance.debugSet(me: 'me');
      final msgs = StreamController<List<Message>>();
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: ChatDetailScreen(
            other: _other(),
            messages: msgs.stream,
            // other got everything up to minute 6, saw up to minute 4
            chat: Stream.value(
              _chat(seen: {'other': 4}, delivered: {'other': 6}),
            ),
            myUid: 'me',
            presence: Stream.value(DateTime.now()),
          ),
        ),
      );
      msgs.add([
        _m('p', sender: 'me', at: 9, pending: true),
        _m('s', sender: 'me', at: 8),
        _m('d', sender: 'me', at: 5),
        _m('g', sender: 'me', at: 3),
        _m('o', at: 2), // theirs: no tick
      ]);
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('tick-pending')), findsOneWidget);
      expect(find.byKey(const ValueKey('tick-sent')), findsOneWidget);
      expect(find.byKey(const ValueKey('tick-delivered')), findsOneWidget);
      expect(find.byKey(const ValueKey('tick-seen')), findsOneWidget);
      // and "Active now" under the name
      expect(find.text('Active now'), findsOneWidget);
      await msgs.close();
      await _finish(t);
    });

    test('delivered is sent once per new message', () {
      final asked = <String>[];
      Future<void> mark(String id) async => asked.add(id);
      final r = ChatReceipts.instance..stop();
      final chats = [
        _chat(last: 'other', updated: 5), // new from other -> mark
        _chat(last: 'me', updated: 5), // mine -> no
      ];
      r.check('me', chats, mark);
      r.check('me', chats, mark); // same again -> no 2nd write
      expect(asked, ['me_other']);
      // already delivered -> nothing
      asked.clear();
      r
        ..stop()
        ..check('me', [
          _chat(last: 'other', updated: 5, delivered: {'me': 6}),
        ], mark);
      expect(asked, isEmpty);
    });
  });

  // ------------------------------------------------------------ active
  group('active status', () {
    test('labels', () {
      final now = DateTime(2026, 10, 14, 12);
      String? l(Duration d) => Presence.label(now.subtract(d), now: now);
      expect(l(const Duration(minutes: 1)), 'Active now');
      expect(l(const Duration(minutes: 5)), 'Active 5m ago');
      expect(l(const Duration(hours: 3)), 'Active 3h ago');
      expect(l(const Duration(days: 2)), 'Active 2d ago');
      expect(l(const Duration(days: 9)), isNull);
      expect(Presence.label(null), isNull);
      expect(Presence.isNow(now, now: now), isTrue);
    });

    testWidgets('hidden person = no label', (t) async {
      await t.pumpWidget(
        _app(ActiveLabel(uid: 'x', stream: Stream<DateTime?>.value(null))),
      );
      await t.pump();
      expect(find.byKey(const ValueKey('active-label')), findsNothing);
      await _finish(t);
    });

    testWidgets('settings switch turns it off (saved)', (t) async {
      SharedPreferences.setMockInitialValues({});
      Presence.instance.show.value = true;
      await t.pumpWidget(
        MaterialApp(theme: AppTheme.dark, home: const ActivityStatusScreen()),
      );
      await t.tap(find.byKey(const ValueKey('show-activity')));
      await t.pumpAndSettle();
      expect(Presence.instance.show.value, isFalse);
      final p = await SharedPreferences.getInstance();
      expect(p.getBool('show_activity'), isFalse);
      // off = you don't see others either
      expect(await Presence.instance.watch('anyone').first, isNull);
      Presence.instance.show.value = true;
      await _finish(t);
    });
  });

  // ------------------------------------------------------------ reply jump
  testWidgets('tap a reply quote = scroll to the old message + flash', (
    t,
  ) async {
    ContentFilter.instance.debugSet(me: 'me');
    final msgs = StreamController<List<Message>>();
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: ChatDetailScreen(
          other: _other(),
          messages: msgs.stream,
          chat: Stream.value(_chat()),
          myUid: 'me',
        ),
      ),
    );
    msgs.add([
      _m(
        'new',
        sender: 'me',
        text: 'answer',
        at: 200,
        extra: {
          'replyTo': {'id': 'm140', 'senderId': 'other', 'text': 'old one'},
        },
      ),
      for (var i = 1; i < 150; i++) _m('m$i', text: 'message $i', at: 150 - i),
    ]);
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey('msg-m140')), findsNothing); // far up
    await t.tap(find.byKey(const ValueKey('quote-new')));
    for (var i = 0; i < 40; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    final target = find.byKey(const ValueKey('msg-m140'));
    expect(target, findsOneWidget);
    final y = t.getCenter(target).dy;
    expect(y, inInclusiveRange(0, 600));
    // highlighted for a moment
    final box = t.widget<AnimatedContainer>(
      find.ancestor(of: target, matching: find.byType(AnimatedContainer)).first,
    );
    expect((box.decoration as BoxDecoration?)?.color, isNot(Colors.transparent));
    await msgs.close();
    await _finish(t);
  });

  // ------------------------------------------------------------ calls
  group('calls', () {
    test('end texts', () {
      expect(endText(CallStatus.declined, outgoing: true), 'Call declined');
      expect(endText(CallStatus.missed, outgoing: true), 'No answer');
      expect(endText(CallStatus.missed, outgoing: false), 'Missed call');
      expect(endText(CallStatus.busy, outgoing: true), 'Busy on another call');
      expect(endText(CallStatus.ended, outgoing: false), 'Call ended');
    });

    test('ICE servers from the server are checked', () {
      final l = IceServers.parse([
        {
          'urls': ['turn:turn.cloudflare.com:3478?transport=udp'],
          'username': 'u',
          'credential': 'c',
        },
        {'urls': 'stun:stun.cloudflare.com:3478'},
        {'urls': 5},
        'junk',
      ]);
      expect(l.length, 2);
      expect(l.first['username'], 'u');
      expect(l.last['urls'], ['stun:stun.cloudflare.com:3478']);
      expect(IceServers.parse(null), isEmpty);
    });

    testWidgets('call screen: "Calling…" then a clear error', (t) async {
      final start = Completer<CallSession>();
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: CallScreen(
            peer: const CallPeer(uid: 'other', name: 'sam'),
            video: true,
            outgoing: true,
            start: () => start.future,
          ),
        ),
      );
      await t.pump();
      expect(find.text('sam'), findsOneWidget);
      expect(find.text('Calling…'), findsOneWidget);
      expect(find.byKey(const ValueKey('call-end')), findsOneWidget);
      expect(find.byKey(const ValueKey('call-flip')), findsOneWidget);
      start.completeError(Exception('NotAllowedError: Permission denied'));
      await t.pump();
      await t.pump();
      expect(
        find.text('Allow camera and microphone to make video calls.'),
        findsOneWidget,
      );
      await _finish(t);
    });

    test('calls off in tests', () async {
      expect(
        () => Calls.instance.call(uid: 'x', username: 'x', video: false),
        throwsA(isA<CallsOff>()),
      );
    });
  });
}
