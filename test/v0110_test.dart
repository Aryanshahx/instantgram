import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/services/calls.dart';
import 'package:instantgram/core/services/chat_prefs.dart';
import 'package:instantgram/core/services/content_filter.dart';
import 'package:instantgram/core/services/presence.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/calls/call_session.dart';
import 'package:instantgram/features/calls/incoming_call_screen.dart';
import 'package:instantgram/features/chats/data/chat_repository.dart';
import 'package:instantgram/features/chats/presentation/chat_detail_screen.dart';
import 'package:instantgram/features/chats/presentation/chats_screen.dart';
import 'package:instantgram/features/chats/presentation/message_widgets.dart';
import 'package:instantgram/features/post/data/report_repository.dart';
import 'package:instantgram/features/post/presentation/comments_sheet.dart';
import 'package:instantgram/features/reels/presentation/clips_screen.dart';
import 'package:instantgram/features/settings/presentation/call_check_screen.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/models/user_profile.dart';
import 'package:instantgram/shared/widgets/net_image.dart';

// v0.11: chat list menu, disappearing messages, call log, muted calls,
// call check, comment menu + pin, clips small/full maths.

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark,
  home: Scaffold(body: child),
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

Chat _chat({String disappear = 'off'}) => Chat.fromMap('me_other', {
  'members': ['me', 'other'],
  'lastSenderId': 'other',
  'lastMessage': 'x',
  'updatedAt': _ts(0),
  'disappear': disappear,
});

Chat _listChat(String other, int updated) => Chat.fromMap('me_$other', {
  'members': ['me', other],
  'memberInfo': {
    other: {'username': other, 'photoUrl': ''},
  },
  'lastSenderId': other,
  'lastMessage': 'hi from $other',
  'updatedAt': _ts(updated),
});

UserProfile _other() =>
    UserProfile.fromMap('other', const {'username': 'sam', 'photoUrl': ''});

Post _post({String pinned = ''}) => Post(
  id: 'p1',
  authorId: 'author',
  authorUsername: 'author',
  authorPhotoUrl: '',
  type: Post.clip,
  mediaUrl: 'https://x.test/a.mp4',
  mediaKey: '',
  caption: '',
  aspectRatio: 1,
  likesCount: 0,
  commentsCount: 0,
  repostsCount: 0,
  viewsCount: 0,
  pinned: false,
  createdAt: DateTime(2026, 1, 1),
  pinnedComment: pinned,
);

Comment _c(String id, String author, int at, {String text = 'nice'}) =>
    Comment.fromMap(id, {
      'authorId': author,
      'authorUsername': author,
      'text': text,
      'createdAt': _ts(at),
    });

Widget _detail({
  required Stream<List<Message>> messages,
  String disappear = 'off',
}) => MaterialApp(
  theme: AppTheme.dark,
  home: ChatDetailScreen(
    other: _other(),
    messages: messages,
    chat: Stream.value(_chat(disappear: disappear)),
    myUid: 'me',
    presence: Stream.value(null),
  ),
);

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
    ChatRepository.debugNoPush = true;
    CallSession.debugNoCallLog = true;
    CommentTile.debugLiked = (id) => Stream.value(false);
    Presence.instance.show.value = false; // no Firestore in tests
    ContentFilter.instance.debugSet(me: 'me');
  });

  tearDown(() => ChatPrefs.instance.debugSet(ChatPrefsData.empty));

  // ------------------------------------------------------- presence
  group('active status', () {
    test('labels use the online flag', () {
      final now = DateTime(2026, 10, 14, 12);
      final ago = now.subtract(const Duration(minutes: 2));
      expect(Presence.label(ago, now: now), 'Active now');
      // left the app 2 minutes ago -> not "now"
      expect(Presence.label(ago, now: now, online: false), 'Active 2m ago');
      expect(
        Presence.label(now.subtract(const Duration(hours: 3)), now: now),
        'Active 3h ago',
      );
      expect(
        Presence.label(now.subtract(const Duration(days: 9)), now: now),
        isNull,
      );
      // phone clock a bit ahead is fine
      expect(
        Presence.label(now.add(const Duration(seconds: 30)), now: now),
        'Active now',
      );
      expect(Presence.labelOf(null), isNull);
    });
  });

  // ------------------------------------------------------- chat list
  group('chat list: pin / mute / delete', () {
    test('pinned first, deleted chats hidden until a new message', () {
      final chats = [_listChat('a', 1), _listChat('b', 9), _listChat('c', 5)];
      final p = ChatPrefsData(
        pinned: const ['me_a'],
        cleared: {'me_c': _t0.add(const Duration(minutes: 6))},
      );
      final out = ChatPrefs.sortChats<Chat>(
        chats,
        p,
        id: (c) => c.id,
        updatedAt: (c) => c.updatedAt,
      );
      expect(out.map((c) => c.id), ['me_a', 'me_b']);
      // a new message after "delete" brings it back
      final back = ChatPrefs.sortChats<Chat>(
        [...chats.take(2), _listChat('c', 7)],
        p,
        id: (c) => c.id,
        updatedAt: (c) => c.updatedAt,
      );
      expect(back.map((c) => c.id), ['me_a', 'me_b', 'me_c']);
    });

    testWidgets('icons + long-press menu', (t) async {
      ChatPrefs.instance.debugSet(
        const ChatPrefsData(
          pinned: ['me_a'],
          mutedChats: {'me_b'},
          mutedCalls: {'c'},
        ),
      );
      await t.pumpWidget(
        _app(
          ChatsScreen(
            myUid: 'me',
            chats: Stream.value([
              _listChat('a', 1),
              _listChat('b', 9),
              _listChat('c', 5),
            ]),
          ),
        ),
      );
      await t.pump();
      await t.pump();
      Finder inTile(String chat, String key) => find.descendant(
        of: find.byKey(ValueKey('chat-$chat')),
        matching: find.byKey(ValueKey(key)),
      );
      expect(inTile('me_a', 'chat-pinned-icon'), findsOneWidget);
      expect(inTile('me_b', 'chat-muted-icon'), findsOneWidget);
      expect(inTile('me_c', 'chat-calls-muted-icon'), findsOneWidget);
      expect(inTile('me_b', 'chat-pinned-icon'), findsNothing);
      // pinned "a" is on top although it is the oldest
      final ya = t.getTopLeft(find.byKey(const ValueKey('chat-me_a'))).dy;
      final yb = t.getTopLeft(find.byKey(const ValueKey('chat-me_b'))).dy;
      expect(ya, lessThan(yb));

      await t.longPress(find.byKey(const ValueKey('chat-me_b')));
      await t.pumpAndSettle();
      for (final id in ['pin', 'mute', 'calls', 'delete']) {
        expect(find.byKey(ValueKey('chat-menu-$id')), findsOneWidget);
      }
      expect(find.text('Unmute messages'), findsOneWidget);
      expect(find.text('Mute calls'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('chat-menu-delete')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-delete-yes')), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      await _finish(t);
    });

    testWidgets('max 3 pinned chats', (t) async {
      ChatPrefs.instance.debugSet(
        const ChatPrefsData(pinned: ['me_x', 'me_y', 'me_z']),
      );
      await t.pumpWidget(
        _app(
          ChatsScreen(myUid: 'me', chats: Stream.value([_listChat('a', 1)])),
        ),
      );
      await t.pump();
      await t.pump();
      await t.longPress(find.byKey(const ValueKey('chat-me_a')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('chat-menu-pin')));
      await t.pumpAndSettle();
      expect(find.text('You can pin up to 3 chats'), findsOneWidget);
      await _finish(t);
    });
  });

  // ------------------------------------------------------- disappearing
  group('disappearing messages', () {
    test('modes and message fields', () {
      expect(Disappear.normalize('nope'), Disappear.off);
      expect(Disappear.standard, '24h');
      expect(Disappear.label(Disappear.week), '7 days');
      expect(ChatRepository.disappearFields('off', _t0), isEmpty);
      expect(ChatRepository.disappearFields('seen', _t0), {'vanish': true});
      final day = ChatRepository.disappearFields('24h', _t0);
      expect(
        (day['expireAt'] as Timestamp).toDate(),
        _t0.add(const Duration(hours: 24)),
      );
      final week = ChatRepository.disappearFields('7d', _t0);
      expect(
        (week['expireAt'] as Timestamp).toDate(),
        _t0.add(const Duration(days: 7)),
      );
    });

    test('visible: expired, once-seen, deleted chat, hidden for me', () {
      final now = _t0.add(const Duration(minutes: 30));
      final all = [
        _m('ok', at: 20),
        _m('exp', at: 1, extra: {'expireAt': _ts(10)}),
        _m('live', at: 1, extra: {'expireAt': _ts(100)}),
        _m('v-old', at: 2, extra: {'vanish': true}), // I saw it before
        _m('v-new', at: 25, extra: {'vanish': true}), // not yet
        _m('v-mine', sender: 'me', at: 2, extra: {'vanish': true}),
        _m(
          'hid',
          at: 21,
          extra: {
            'hiddenFor': ['me'],
          },
        ),
        _m('before-delete', at: 0),
      ];
      final ids = ChatRepository.visible(
        all,
        me: 'me',
        now: now,
        seenBefore: _t0.add(const Duration(minutes: 5)),
        clearedAt: _t0,
      ).map((m) => m.id);
      expect(ids, ['ok', 'live', 'v-new', 'v-mine']);
      expect(all[1].disappears, isTrue);
      expect(all[1].expiredAt(now), isTrue);
      expect(all[2].expiredAt(now), isFalse);
    });

    testWidgets('timer button: pick a mode, the bar shows', (t) async {
      final msgs = StreamController<List<Message>>();
      await t.pumpWidget(_detail(messages: msgs.stream));
      msgs.add([_m('a', text: 'hi')]);
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('disappear-bar')), findsNothing);
      // v0.0.1 fix: in the ⋯ menu now
      await t.tap(find.byKey(const ValueKey('chat-more')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('disappear-btn')));
      await t.pumpAndSettle();
      for (final m in Disappear.all) {
        expect(find.byKey(ValueKey('disappear-$m')), findsOneWidget);
      }
      await t.tap(find.byKey(const ValueKey('disappear-7d')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('disappear-bar')), findsOneWidget);
      expect(find.text('Disappearing messages · 7 days'), findsOneWidget);
      await msgs.close();
      await _finish(t);
    });

    testWidgets('slide up and hold = on (24 h), again = off', (t) async {
      final msgs = StreamController<List<Message>>();
      await t.pumpWidget(_detail(messages: msgs.stream));
      msgs.add([for (var i = 0; i < 3; i++) _m('m$i', at: -i)]);
      await t.pump();
      await t.pump();
      Future<void> slide() async {
        final g = await t.startGesture(const Offset(200, 400));
        for (var i = 0; i < 12; i++) {
          await g.moveBy(const Offset(0, -20));
          await t.pump(const Duration(milliseconds: 16));
        }
        expect(find.byKey(const ValueKey('vanish-hint')), findsOneWidget);
        expect(find.textContaining('Release to turn'), findsOneWidget);
        await g.up();
        await t.pumpAndSettle();
      }

      await slide();
      expect(find.byKey(const ValueKey('disappear-bar')), findsOneWidget);
      expect(find.text('Disappearing messages · 24 hours'), findsOneWidget);
      await slide();
      expect(find.byKey(const ValueKey('disappear-bar')), findsNothing);
      // a small slide does nothing
      final g = await t.startGesture(const Offset(200, 400));
      await g.moveBy(const Offset(0, -40));
      await t.pump();
      await g.up();
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('disappear-bar')), findsNothing);
      await msgs.close();
      await _finish(t);
    });

    testWidgets('system note, timer icon, once-seen icon', (t) async {
      // v0.14: the chat's mode again (both people)
      final msgs = StreamController<List<Message>>();
      await t.pumpWidget(_detail(messages: msgs.stream, disappear: '24h'));
      final later = Timestamp.fromDate(
        DateTime.now().add(const Duration(hours: 5)),
      );
      msgs.add([
        _m('t1', sender: 'me', at: 3, extra: {'expireAt': later}),
        _m('v1', at: 2, extra: {'vanish': true}),
        _m(
          's1',
          at: 1,
          text: 'sam turned on disappearing messages: 24 hours',
          extra: {'kind': 'system'},
        ),
      ]);
      await t.pump();
      await t.pump();
      expect(find.byType(SystemNote), findsOneWidget);
      expect(find.byKey(const ValueKey('vanish-t1')), findsOneWidget);
      expect(find.byKey(const ValueKey('vanish-v1')), findsOneWidget);
      expect(find.byKey(const ValueKey('disappear-bar')), findsOneWidget);
      // tap the note = mode picker
      await t.tap(find.byType(SystemNote));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('disappear-seen')), findsOneWidget);
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      await msgs.close();
      await _finish(t);
    });
  });

  // ------------------------------------------------------- call log
  group('call messages', () {
    test('labels', () {
      Message call(String st, {bool video = false, int sec = 0}) => _m(
        'c',
        extra: {
          'kind': 'call',
          'callStatus': st,
          'video': video,
          'durationSec': sec,
        },
      );
      expect(call('ended', sec: 151).callLabel, 'Voice call · 2:31');
      expect(call('missed', video: true).callLabel, 'Missed video call');
      expect(call('busy').callLabel, 'Missed voice call');
      expect(call('declined', video: true).callLabel, 'Video call declined');
      expect(call('failed').callLabel, 'Call failed');
      expect(call('ended').callLabel, 'Voice call');
      expect(call('ended').isCall, isTrue);
      expect(_m('s', extra: {'kind': 'system'}).isSystem, isTrue);
    });

    testWidgets('shows in the chat, no ticks, tap = call back', (t) async {
      final msgs = StreamController<List<Message>>();
      await t.pumpWidget(_detail(messages: msgs.stream));
      msgs.add([
        _m(
          'c1',
          sender: 'me',
          at: 2,
          extra: {
            'kind': 'call',
            'callStatus': 'ended',
            'video': false,
            'durationSec': 65,
          },
        ),
        _m(
          'c2',
          at: 1,
          extra: {
            'kind': 'call',
            'callStatus': 'missed',
            'video': true,
            'durationSec': 0,
          },
        ),
      ]);
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('call-log-c1')), findsOneWidget);
      expect(find.text('Voice call · 1:05'), findsOneWidget);
      expect(find.text('Missed video call'), findsOneWidget);
      expect(find.byKey(const ValueKey('tick-sent')), findsNothing);
      expect(find.byKey(const ValueKey('tick-seen')), findsNothing);
      await t.tap(find.byKey(const ValueKey('call-log-c2')));
      await t.pump();
      await t.pump();
      // calls are off in tests -> the reason shows
      expect(find.byType(SnackBar), findsOneWidget);
      await msgs.close();
      await _finish(t);
    });
  });

  // ------------------------------------------------------- muted call
  group('muted incoming call', () {
    testWidgets('silent screen, closes when the caller hangs up', (t) async {
      final status = StreamController<String?>();
      var accepted = 0;
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => IncomingCallScreen(
                        callId: 'c1',
                        peer: const CallPeer(uid: 'other', name: 'sam'),
                        video: true,
                        onAccept: () => accepted++,
                        onDecline: () {},
                        status: status.stream,
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      expect(find.text('sam'), findsOneWidget);
      expect(find.text('Muted video call'), findsOneWidget);
      expect(find.byKey(const ValueKey('incoming-accept')), findsOneWidget);
      expect(find.byKey(const ValueKey('incoming-decline')), findsOneWidget);
      status.add('ringing');
      await t.pump();
      expect(find.byType(IncomingCallScreen), findsOneWidget);
      status.add('ended'); // caller hung up
      await t.pumpAndSettle();
      expect(find.byType(IncomingCallScreen), findsNothing);
      expect(accepted, 0);
      // the screen stopped listening: don't wait for close()
      unawaited(status.close());
      await _finish(t);
    });

    testWidgets('accept once', (t) async {
      var accepted = 0;
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: IncomingCallScreen(
            callId: 'c1',
            peer: const CallPeer(uid: 'other', name: 'sam'),
            video: false,
            onAccept: () => accepted++,
            onDecline: () {},
            status: const Stream<String?>.empty(),
          ),
        ),
      );
      await t.pump();
      expect(find.text('Muted voice call'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('incoming-accept')));
      await t.tap(find.byKey(const ValueKey('incoming-accept')));
      await t.pump();
      expect(accepted, 1);
      await t.pumpWidget(const SizedBox());
      await _finish(t);
    });
  });

  // ------------------------------------------------------- call check
  group('calls & notifications check', () {
    testWidgets('problems, fix buttons, phone tip, no test ring', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: CallCheckScreen(
            maker: 'oppo',
            check: () async => const CallCheck(
              notifications: true,
              fullScreen: false,
              battery: false,
              registered: true,
            ),
          ),
        ),
      );
      await t.pump();
      await t.pump();
      expect(
        find.text('Fix the items below so calls ring when the app is closed.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('fix-notifications')), findsNothing);
      expect(find.byKey(const ValueKey('fix-fullscreen')), findsOneWidget);
      expect(find.byKey(const ValueKey('fix-battery')), findsOneWidget);
      expect(find.byKey(const ValueKey('fix-registered')), findsNothing);
      expect(find.byKey(const ValueKey('check-autostart')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-ring')), findsNothing);
      await _finish(t);
    });

    testWidgets('all good, no tip on other phones', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: CallCheckScreen(
            maker: 'samsung',
            check: () async => const CallCheck(
              notifications: true,
              fullScreen: true,
              battery: true,
              registered: true,
            ),
          ),
        ),
      );
      await t.pump();
      await t.pump();
      expect(find.text('This phone is ready to ring.'), findsOneWidget);
      expect(find.byKey(const ValueKey('check-autostart')), findsNothing);
      expect(find.text('Fix'), findsNothing);
      await _finish(t);
    });
  });

  // ------------------------------------------------------- comments
  group('comments: long-press menu + pin', () {
    testWidgets('author sees pin; pinned comment is first', (t) async {
      final ctrl = StreamController<List<Comment>>();
      await t.pumpWidget(
        _app(
          CommentsSheet(
            post: _post(pinned: 'c3'),
            stream: ctrl.stream,
            myUid: 'author',
          ),
        ),
      );
      ctrl.add([
        _c('c1', 'bob', 1, text: 'first'),
        _c('c2', 'carol', 2, text: 'second'),
        _c('c3', 'dave', 3, text: 'best one'),
      ]);
      await t.pump();
      await t.pump();
      final y3 = t.getTopLeft(find.byKey(const ValueKey('comment-c3'))).dy;
      final y1 = t.getTopLeft(find.byKey(const ValueKey('comment-c1'))).dy;
      expect(y3, lessThan(y1));
      expect(find.byKey(const ValueKey('comment-pinned')), findsOneWidget);
      expect(find.text('Pinned by author'), findsOneWidget);

      await t.longPress(find.text('second'));
      await t.pumpAndSettle();
      for (final id in ['pin', 'share', 'report', 'delete']) {
        expect(
          find.byKey(ValueKey('comment-menu-$id')),
          findsOneWidget,
          reason: id,
        );
      }
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      await ctrl.close();
      await _finish(t);
    });

    testWidgets('others: share + report only; own: delete, no report', (
      t,
    ) async {
      final ctrl = StreamController<List<Comment>>();
      await t.pumpWidget(
        _app(CommentsSheet(post: _post(), stream: ctrl.stream, myUid: 'bob')),
      );
      ctrl.add([
        _c('c1', 'bob', 1, text: 'mine'),
        _c('c2', 'carol', 2, text: 'hers'),
      ]);
      await t.pump();
      await t.pump();
      await t.longPress(find.text('hers'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('comment-menu-pin')), findsNothing);
      expect(find.byKey(const ValueKey('comment-menu-share')), findsOneWidget);
      expect(find.byKey(const ValueKey('comment-menu-report')), findsOneWidget);
      expect(find.byKey(const ValueKey('comment-menu-delete')), findsNothing);
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      await t.longPress(find.text('mine'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('comment-menu-pin')), findsNothing);
      expect(find.byKey(const ValueKey('comment-menu-report')), findsNothing);
      expect(find.byKey(const ValueKey('comment-menu-delete')), findsOneWidget);
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      await ctrl.close();
      await _finish(t);
    });

    test('share text + report email', () {
      final p = _post();
      final c = _c('c9', 'carol', 1, text: 'so good');
      final share = commentShareText(p, c);
      expect(share, contains('"so good"'));
      expect(share, contains('@carol'));
      expect(share, contains('clip by @author'));
      final mail = ReportRepository.commentEmail(
        post: p,
        comment: c,
        reporterUsername: 'bob',
        reporterUid: 'u-bob',
      );
      expect(mail.subject, 'Report: comment by @carol');
      expect(mail.body, contains('Comment ID: c9'));
      expect(mail.body, contains('Comment: so good'));
      expect(mail.body, contains('Clip ID: p1'));
      expect(mail.body, contains('Reported by: @bob (u-bob)'));
    });
  });

  // ------------------------------------------------------- clips
  group('clips: small / full maths', () {
    test('bigness follows the comments panel', () {
      const h = 800.0;
      expect(ClipLayout.bigness(null, h), 1); // no panel
      expect(ClipLayout.bigness(h, h), 1); // closed
      expect(ClipLayout.bigness(0.4 * h, h), 0); // open (40 %)
      expect(ClipLayout.bigness(0.1 * h, h), 0); // full screen
      expect(ClipLayout.bigness(0.7 * h, h), closeTo(0.5, 1e-9));
    });

    test('cover scale fills the screen', () {
      expect(ClipLayout.coverScale(400, 800, 0.5), closeTo(1, 1e-9));
      expect(ClipLayout.coverScale(400, 800, 9 / 16), closeTo(1.125, 1e-9));
      expect(ClipLayout.coverScale(400, 800, 16 / 9), closeTo(3.5556, 1e-3));
      expect(ClipLayout.coverScale(0, 800, 1), 1);
      expect(ClipLayout.coverScale(400, 800, 0), 1);
    });
  });
}
