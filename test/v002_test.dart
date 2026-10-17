import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/services/account_family.dart';
import 'package:instantgram/core/services/api_client.dart';
import 'package:instantgram/core/services/calls.dart';
import 'package:instantgram/core/services/chat_prefs.dart';
import 'package:instantgram/core/services/content_filter.dart';
import 'package:instantgram/core/services/live_photos.dart';
import 'package:instantgram/core/services/saved_accounts.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/calls/call_session.dart';
import 'package:instantgram/features/chats/data/channel_seen.dart';
import 'package:instantgram/features/chats/data/channel_topics.dart';
import 'package:instantgram/features/chats/data/chat_repository.dart';
import 'package:instantgram/features/chats/data/group_repository.dart';
import 'package:instantgram/features/chats/presentation/chat_detail_screen.dart';
import 'package:instantgram/features/chats/presentation/chats_screen.dart';
import 'package:instantgram/features/chats/presentation/group_screens.dart';
import 'package:instantgram/features/chats/presentation/group_widgets.dart';
import 'package:instantgram/features/chats/presentation/message_widgets.dart';
import 'package:instantgram/features/editor/cover_render.dart';
import 'package:instantgram/features/post/presentation/comments_sheet.dart';
import 'package:instantgram/features/settings/presentation/accounts_screen.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/models/user_profile.dart';
import 'package:instantgram/shared/widgets/media_links.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:instantgram/shared/widgets/username_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

// v0.0.2: groups + channels, same-login accounts, username check, link
// stickers, edited covers, live photos, camera flip, chat themes, replies.

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark,
  home: Scaffold(body: child),
);

final _t0 = DateTime(2026, 10, 14, 12);
Timestamp _ts(int minutes) =>
    Timestamp.fromDate(_t0.add(Duration(minutes: minutes)));

const _g = 'g_AAAAAAAAAAAAAAAAAAAA';
const _ch = 'ch_BBBBBBBBBBBBBBBBBBBB';

Chat _group({
  List<String> members = const ['me', 'bob', 'cat'],
  List<String> admins = const ['me'],
  Map<String, int> seen = const {},
  Map<String, int> delivered = const {},
  Map<String, int> typing = const {},
  String last = 'bob',
  String lastName = 'bob',
  String text = 'hi all',
  int updated = 10,
  String id = _g,
}) => Chat.fromMap(id, {
  'name': id == _g ? 'Friends' : 'News',
  'photoUrl': '',
  'description': id == _g ? '' : 'Daily news',
  'members': members,
  'admins': admins,
  'createdBy': admins.first,
  'memberInfo': {
    for (final u in members) u: {'username': u, 'photoUrl': ''},
  },
  'lastMessage': text,
  'lastSenderId': last,
  'lastSenderName': lastName,
  'updatedAt': _ts(updated),
  'seen': {for (final e in seen.entries) e.key: _ts(e.value)},
  'delivered': {for (final e in delivered.entries) e.key: _ts(e.value)},
  // typing stamps are "now" (old ones are ignored)
  'typing': {for (final u in typing.keys) u: Timestamp.now()},
});

Message _m(
  String id, {
  String sender = 'bob',
  int at = 0,
  String text = 'hello',
}) => Message.fromMap(id, {
  'senderId': sender,
  'text': text,
  'createdAt': _ts(at),
});

UserProfile _groupProfile(String id, String name) =>
    UserProfile(uid: id, name: '', username: name, photoUrl: '');

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _finish(WidgetTester t) async {
  await t.pump(const Duration(seconds: 12));
  await t.pumpAndSettle();
}

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
  setUpAll(() {
    NetImage.disableCache = true;
    VoiceBubble.disabled = true;
    Calls.disabled = true;
    LivePhotos.disabled = true;
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ContentFilter.instance.debugSet(me: 'me');
  });

  // =============================================================== groups
  group('groups + channels: data', () {
    test('Chat knows groups / channels by id', () {
      final g = _group();
      expect(g.isGroup, isTrue);
      expect(g.isChannel, isFalse);
      expect(g.isMulti, isTrue);
      expect(g.name, 'Friends');
      expect(g.isAdmin('me'), isTrue);
      expect(g.isAdmin('bob'), isFalse);
      expect(g.isMember('cat'), isTrue);
      expect(g.lastSenderName, 'bob');
      final c = _group(id: _ch);
      expect(c.isChannel, isTrue);
      expect(c.description, 'Daily news');
      final dm = Chat.fromMap('me_other', const {
        'members': ['me', 'other'],
      });
      expect(dm.isMulti, isFalse);
      expect(Chat.typeOfId('g_x'), Chat.group);
      expect(Chat.typeOfId('ch_x'), Chat.channel);
      expect(Chat.typeOfId('a_b'), '');
    });

    test('ids, collections, names', () {
      final id = GroupRepository.newId('g_');
      expect(id, matches(RegExp(r'^g_[A-Za-z0-9]{20}$')));
      expect(
        GroupRepository.newId('ch_'),
        matches(RegExp(r'^ch_[A-Za-z0-9]{20}$')),
      );
      expect(ChatRepository.isGroupId(_g), isTrue);
      expect(ChatRepository.isGroupId(_ch), isTrue);
      expect(ChatRepository.isGroupId('alice_bob'), isFalse);
      expect(ChatRepository.isChannelId(_ch), isTrue);
      expect(ChatRepository.collectionOf(_g), 'groups');
      expect(ChatRepository.collectionOf(_ch), 'channels');
      expect(ChatRepository.collectionOf('a_b'), 'chats');
      expect(GroupRepository.cleanName('  My    group  '), 'My group');
      expect(
        GroupRepository.cleanName('x' * 80).length,
        GroupRepository.maxName,
      );
      expect(GroupRepository.namesText(['a']), 'a');
      expect(GroupRepository.namesText(['a', 'b']), 'a and b');
      expect(GroupRepository.namesText(['a', 'b', 'c']), 'a, b and c');
      expect(
        GroupRepository.namesText(['a', 'b', 'c', 'd', 'e']),
        'a, b and 3 others',
      );
      expect(groupTypingText(['bob']), 'bob is typing…');
      expect(groupTypingText(['bob', 'cat']), 'bob and cat are typing…');
      expect(groupTypingText(['a', 'b', 'c']), '3 people are typing…');
      expect(memberCountText(1, channel: false), '1 member');
      expect(memberCountText(3, channel: false), '3 members');
      expect(memberCountText(1500, channel: true), '1.5K followers');
      expect(memberCountText(12000, channel: true), '12K followers');
      expect(memberCountText(2000, channel: true), '2K followers');
    });

    test('last admin leaving: the oldest member becomes admin', () {
      final g = _group(members: ['me', 'bob', 'cat'], admins: ['me']);
      expect(GroupRepository.nextAdmin(g, 'me'), 'bob');
      expect(GroupRepository.nextAdmin(g, 'bob'), isNull); // not admin
      final two = _group(members: ['me', 'bob'], admins: ['me', 'bob']);
      expect(GroupRepository.nextAdmin(two, 'me'), isNull); // bob stays
      final alone = _group(members: ['me'], admins: ['me']);
      expect(GroupRepository.nextAdmin(alone, 'me'), isNull);
    });

    test('chat list = chats + groups + channels, newest first; broken '
        'extra lists are skipped', () async {
      final main = StreamController<List<Chat>>();
      final groups = StreamController<List<Chat>>();
      final channels = StreamController<List<Chat>>();
      final out = <List<String>>[];
      final sub = ChatRepository.mergeChatLists(main.stream, [
        groups.stream,
        channels.stream,
      ]).listen((v) => out.add([for (final c in v) c.id]));
      groups.add([_group(updated: 20)]);
      await Future<void>.delayed(Duration.zero);
      expect(out, isEmpty); // waits for the main list
      main.add([
        Chat.fromMap('a_b', {
          'members': ['a', 'b'],
          'updatedAt': _ts(30),
        }),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(out.last, ['a_b', _g]);
      channels.addError(Exception('permission-denied'));
      await Future<void>.delayed(Duration.zero);
      expect(out.last, ['a_b', _g]);
      channels.add([_group(id: _ch, updated: 40)]);
      await Future<void>.delayed(Duration.zero);
      expect(out.last, [_ch, 'a_b', _g]);
      await sub.cancel();
      await main.close();
      await groups.close();
      await channels.close();
    });

    test('chat id: a group id stays the same', () {
      expect(
        ChatPerson(uid: _g, username: 'Friends', photoUrl: '').isGroup,
        isTrue,
      );
      expect(
        const ChatPerson(uid: 'bob', username: 'bob', photoUrl: '').isGroup,
        isFalse,
      );
    });

    test('channel unread dot (kept on the phone)', () {
      final c = _group(id: _ch, last: 'boss', updated: 10);
      final at10 = _t0.add(const Duration(minutes: 10)).millisecondsSinceEpoch;
      expect(ChannelSeen.unreadIn(c, 'me', null), isTrue);
      expect(ChannelSeen.unreadIn(c, 'me', at10 - 1), isTrue);
      expect(ChannelSeen.unreadIn(c, 'me', at10), isFalse);
      expect(
        ChannelSeen.unreadIn(_group(id: _ch, last: 'me'), 'me', null),
        isFalse,
      );
    });

    test('push topics: followed channels not muted + own id', () {
      final chats = [
        _group(id: _ch, members: ['me', 'x']),
        _group(id: 'ch_CCCCCCCCCCCCCCCCCCCC', members: ['me']),
        _group(id: 'ch_DDDDDDDDDDDDDDDDDDDD', members: ['x']), // not following
        _group(), // a group: no topic
      ];
      final w = ChannelTopics.wanted(
        'me',
        chats,
        (id) => id == 'ch_CCCCCCCCCCCCCCCCCCCC',
      );
      expect(w, {'u_me', _ch});
    });

    test('push topics are applied and cleaned on sign out', () async {
      final calls = <String>[];
      final topics = ChannelTopics.instance
        ..debugSet = (topic, on) async {
          calls.add('${on ? '+' : '-'}$topic');
          return true;
        };
      topics.update('me', [
        _group(id: _ch, members: ['me']),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls..sort(), ['+$_ch', '+u_me']);
      calls.clear();
      topics.update('me', const []); // unfollowed
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, ['-$_ch']);
      calls.clear();
      await topics.stop();
      expect(calls, ['-u_me']);
      topics.debugSet = null;
    });
  });

  group('groups + channels: screens', () {
    testWidgets('group chat: name, members, no calls, sender names, '
        'blue ticks when everyone saw it', (t) async {
      final msgs = StreamController<List<Message>>();
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: ChatDetailScreen(
            other: _groupProfile(_g, 'Friends'),
            messages: msgs.stream,
            chat: Stream.value(
              _group(
                seen: {'bob': 6, 'cat': 4},
                delivered: {'bob': 9, 'cat': 9},
              ),
            ),
            myUid: 'me',
          ),
        ),
      );
      msgs.add([
        _m('m3', sender: 'me', at: 8), // both got it, not seen by all
        _m('m2', sender: 'me', at: 3), // both saw it
        _m('b2', sender: 'bob', at: 2, text: 'second'),
        _m('b1', sender: 'bob', at: 1, text: 'first'),
        _m('c1', sender: 'cat', at: 0, text: 'meow'),
      ]);
      await _settle(t);
      expect(find.byKey(const ValueKey('group-header')), findsOneWidget);
      expect(find.text('Friends'), findsOneWidget);
      expect(find.text('3 members'), findsOneWidget);
      expect(find.byKey(const ValueKey('call-voice')), findsNothing);
      expect(find.byKey(const ValueKey('call-video')), findsNothing);
      expect(find.byKey(const ValueKey('chat-more')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-info-btn')), findsOneWidget);
      // ⋯ menu: chat theme, no disappearing messages in groups
      await t.tap(find.byKey(const ValueKey('chat-more')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-theme-btn')), findsOneWidget);
      expect(find.byKey(const ValueKey('disappear-btn')), findsNothing);
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      // the name once per run of messages from one person
      expect(find.byKey(const ValueKey('sender-b1')), findsOneWidget);
      expect(find.byKey(const ValueKey('sender-b2')), findsNothing);
      expect(find.byKey(const ValueKey('sender-c1')), findsOneWidget);
      expect(find.byKey(const ValueKey('sender-m2')), findsNothing);
      expect(find.byKey(const ValueKey('tick-seen')), findsOneWidget);
      expect(find.byKey(const ValueKey('tick-delivered')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      await msgs.close();
      await _finish(t);
    });

    testWidgets('group: who is typing in the header', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: ChatDetailScreen(
            other: _groupProfile(_g, 'Friends'),
            messages: Stream.value(const []),
            chat: Stream.value(_group(typing: {'bob': 10, 'cat': 10})),
            myUid: 'me',
          ),
        ),
      );
      await _settle(t);
      expect(find.text('bob and cat are typing…'), findsOneWidget);
      // the typing clock is real time: close the screen, then finish
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 12));
    });

    testWidgets('channel: followers read only, others can follow', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: ChatDetailScreen(
            other: _groupProfile(_ch, 'News'),
            messages: Stream.value([_m('p1', sender: 'boss', text: 'Today')]),
            chat: Stream.value(
              _group(id: _ch, members: ['boss', 'me'], admins: ['boss']),
            ),
            myUid: 'me',
          ),
        ),
      );
      await _settle(t);
      expect(find.text('2 followers'), findsOneWidget);
      expect(find.byKey(const ValueKey('channel-only-admins')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-input')), findsNothing);
      expect(find.byKey(const ValueKey('tick-sent')), findsNothing);
      // no sender names in channels
      expect(find.byKey(const ValueKey('sender-p1')), findsNothing);
      await _finish(t);
      await t.pumpWidget(const SizedBox());

      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: ChatDetailScreen(
            other: _groupProfile(_ch, 'News'),
            messages: Stream.value(const []),
            chat: Stream.value(
              _group(id: _ch, members: ['boss'], admins: ['boss']),
            ),
            myUid: 'me',
          ),
        ),
      );
      await _settle(t);
      expect(find.byKey(const ValueKey('channel-join')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-input')), findsNothing);
      await _finish(t);
    });

    testWidgets('channel admin can post; removed member cannot', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: ChatDetailScreen(
            other: _groupProfile(_ch, 'News'),
            messages: Stream.value(const []),
            chat: Stream.value(
              _group(id: _ch, members: ['me', 'x'], admins: ['me']),
            ),
            myUid: 'me',
          ),
        ),
      );
      await _settle(t);
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      await _finish(t);
      await t.pumpWidget(const SizedBox());

      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: ChatDetailScreen(
            other: _groupProfile(_g, 'Friends'),
            messages: Stream.value(const []),
            chat: Stream.value(
              _group(members: ['bob', 'cat'], admins: ['bob']),
            ),
            myUid: 'me',
          ),
        ),
      );
      await _settle(t);
      expect(find.byKey(const ValueKey('group-not-member')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-input')), findsNothing);
      await _finish(t);
    });

    testWidgets(
      'message menu: admins delete anyone, followers no reply / pin',
      (t) async {
        MessageMenuResult? r;
        Future<void> open({required bool admin, required bool follower}) async {
          await t.pumpWidget(
            _app(
              Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    r = await showMessageMenu(
                      context,
                      message: _m('x'),
                      mine: false,
                      pinned: false,
                      canDeleteAll: admin,
                      canReply: !follower,
                      canPin: !follower,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          );
          await t.tap(find.text('open'));
          await t.pumpAndSettle();
        }

        await open(admin: true, follower: false);
        expect(find.byKey(const ValueKey('msg-deleteAll')), findsOneWidget);
        expect(find.byKey(const ValueKey('msg-reply')), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('msg-deleteAll')));
        await t.pumpAndSettle();
        expect(r?.action, MessageAction.deleteAll);

        await open(admin: false, follower: true);
        expect(find.byKey(const ValueKey('msg-deleteAll')), findsNothing);
        expect(find.byKey(const ValueKey('msg-reply')), findsNothing);
        expect(find.byKey(const ValueKey('msg-pin')), findsNothing);
        expect(find.byKey(const ValueKey('msg-forward')), findsOneWidget);
      },
    );

    testWidgets('chat list: group + channel tiles, "+" menu', (t) async {
      await t.pumpWidget(
        _app(
          ChatsScreen(
            myUid: 'me',
            chats: Stream.value([
              _group(updated: 20),
              _group(
                id: _ch,
                members: ['boss', 'me'],
                admins: ['boss'],
                last: 'boss',
                lastName: '',
                text: 'Big news',
                updated: 15,
              ),
              _group(
                id: 'g_EEEEEEEEEEEEEEEEEEEE',
                last: 'me',
                lastName: '',
                text: 'me created the group "Trip"',
                updated: 5,
              ),
            ]),
          ),
        ),
      );
      await _settle(t);
      expect(find.byKey(const ValueKey('chat-$_g')), findsOneWidget);
      expect(find.text('bob: hi all'), findsOneWidget);
      expect(find.text('Big news'), findsOneWidget); // channel: no name
      // system line: no "You:"
      expect(find.text('me created the group "Trip"'), findsOneWidget);
      // never opened the channel -> unread
      expect(find.byKey(const ValueKey('unread-dot')), findsNWidgets(2));
      await t.tap(find.byKey(const ValueKey('chats-new')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('new-chat-group')), findsOneWidget);
      expect(find.byKey(const ValueKey('new-chat-channel')), findsOneWidget);
      expect(find.byKey(const ValueKey('new-chat-find')), findsOneWidget);
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      await _finish(t);
    });

    testWidgets('group info: admins manage, members see the list', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: GroupInfoScreen(
            chatId: _g,
            chat: Stream.value(_group(admins: ['me'])),
            myUid: 'me',
          ),
        ),
      );
      await _settle(t);
      expect(find.byKey(const ValueKey('info-name')), findsOneWidget);
      expect(find.text('Group · 3 members'), findsOneWidget);
      expect(find.byKey(const ValueKey('info-edit')), findsOneWidget);
      expect(find.byKey(const ValueKey('info-add')), findsOneWidget);
      expect(find.byKey(const ValueKey('admin-chip-me')), findsOneWidget);
      expect(find.byKey(const ValueKey('member-bob')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-leave')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('member-bob')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('member-admin')), findsOneWidget);
      expect(find.byKey(const ValueKey('member-remove')), findsOneWidget);
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      await _finish(t);
      await t.pumpWidget(const SizedBox());

      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: GroupInfoScreen(
            chatId: _g,
            chat: Stream.value(_group(admins: ['bob'])),
            myUid: 'me',
          ),
        ),
      );
      await _settle(t);
      expect(find.byKey(const ValueKey('info-edit')), findsNothing);
      expect(find.byKey(const ValueKey('info-add')), findsNothing);
      await t.tap(find.byKey(const ValueKey('member-bob')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('member-profile')), findsOneWidget);
      expect(find.byKey(const ValueKey('member-remove')), findsNothing);
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      await _finish(t);
    });

    testWidgets('channel info: admins + follow button', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: GroupInfoScreen(
            chatId: _ch,
            chat: Stream.value(
              _group(id: _ch, members: ['boss', 'x', 'y'], admins: ['boss']),
            ),
            myUid: 'me',
          ),
        ),
      );
      await _settle(t);
      expect(find.text('Channel · 3 followers'), findsOneWidget);
      expect(find.text('Daily news'), findsOneWidget);
      expect(find.byKey(const ValueKey('member-boss')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('member-x')),
        findsNothing,
      ); // followers hidden
      expect(find.byKey(const ValueKey('info-follow')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-leave')), findsNothing);
      await _finish(t);
    });

    testWidgets('find channels', (t) async {
      final asked = <String>[];
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: FindChannelsScreen(
            myUid: 'me',
            search: (q) async {
              asked.add(q);
              return [
                if (q.isEmpty || 'news'.startsWith(q))
                  _group(id: _ch, members: ['boss', 'me'], admins: ['boss']),
              ];
            },
          ),
        ),
      );
      await _settle(t);
      expect(find.byKey(const ValueKey('channel-$_ch')), findsOneWidget);
      expect(find.text('Following'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('channel-search')), 'zzz');
      await t.pump(const Duration(milliseconds: 400));
      await _settle(t);
      expect(find.text('No channels found'), findsOneWidget);
      expect(asked, ['', 'zzz']);
      await _finish(t);
    });

    testWidgets('people picker returns who you picked', (t) async {
      List<ChatPerson>? got;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                got = await Navigator.of(context).push<List<ChatPerson>>(
                  MaterialPageRoute(
                    builder: (_) => PeoplePickerScreen(
                      title: 'New group',
                      exclude: const {'zed'},
                      loadTargets: () async => const [
                        ChatPerson(uid: 'bob', username: 'bob', photoUrl: ''),
                        ChatPerson(uid: 'cat', username: 'cat', photoUrl: ''),
                        ChatPerson(uid: 'zed', username: 'zed', photoUrl: ''),
                        ChatPerson(uid: _g, username: 'Friends', photoUrl: ''),
                      ],
                      search: (q) async => const [
                        ChatPerson(uid: 'dan', username: 'dan', photoUrl: ''),
                      ],
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('person-bob')), findsOneWidget);
      expect(find.byKey(const ValueKey('person-zed')), findsNothing);
      expect(find.byKey(const ValueKey('person-$_g')), findsNothing);
      await t.tap(find.byKey(const ValueKey('person-bob')));
      await t.pump();
      await t.enterText(find.byKey(const ValueKey('people-search')), 'dan');
      await t.pump(const Duration(milliseconds: 400));
      await _settle(t);
      await t.tap(find.byKey(const ValueKey('person-dan')));
      await t.pump();
      expect(find.text('Next (2)'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('people-next')));
      await t.pumpAndSettle();
      expect(got?.map((p) => p.uid).toList(), ['bob', 'dan']);
    });
  });

  // ============================================================ accounts
  group('same login, many accounts', () {
    tearDown(() {
      AccountFamily.instance.resetLogin();
      SavedAccounts.instance.debugReset();
    });

    test('list / switch token / create', () async {
      final fam = AccountFamily.instance;
      final sent = <Map<String, dynamic>>[];
      fam.call = (body) async {
        sent.add(body);
        switch (body['action']) {
          case 'list':
            return {
              'owner': 'u1',
              'accounts': [
                {'uid': 'u1', 'username': 'main'},
                {'uid': 'u2', 'username': 'second', 'photoUrl': 'https://p/2'},
                {'bad': true},
              ],
            };
          case 'switch':
            return {'token': 'tok-${body['uid']}'};
          case 'create':
            return {'uid': 'u3', 'token': 'tok-u3'};
        }
        return {};
      };
      await runReal(() async {
        final list = await fam.refresh(email: 'a@x.com');
        expect(list.map((a) => a.uid), ['u1', 'u2']);
        expect(fam.contains('u2'), isTrue);
        expect(await fam.tokenFor('u2'), 'tok-u2');
        final (uid, token) = await fam.create(
          username: ' New.One ',
          name: ' N ',
        );
        expect((uid, token), ('u3', 'tok-u3'));
        expect(sent.last['username'], 'new.one');
        expect(sent.last['name'], 'N');
        // saved for the switcher (no password needed)
        final saved = await SavedAccounts.instance.load();
        expect(saved.map((a) => a.uid), ['u1', 'u2']);
        expect(saved.every((a) => a.linked && a.email == 'a@x.com'), isTrue);
      });
      fam.call = (body) async => {'token': ''};
      expect(() => fam.tokenFor('u2'), throwsA(isA<ApiException>()));
    });

    test('a saved password works for every account of that email', () async {
      final s = SavedAccounts.instance..debugReset();
      await s.rememberLogin(uid: 'u1', email: 'A@x.com', password: 'secret1');
      await s.rememberFamily(const [
        FamilyAccount(uid: 'u1', username: 'main'),
        FamilyAccount(uid: 'u2', username: 'second'),
      ]);
      final list = await s.load();
      final u2 = list.firstWhere((a) => a.uid == 'u2');
      expect(u2.linked, isTrue);
      expect(u2.email, 'A@x.com'); // from the saved account
      expect(list.firstWhere((a) => a.uid == 'u1').linked, isFalse);
      expect(await s.passwordForEmail('a@X.com '), 'secret1');
      expect(await s.passwordForEmail('b@x.com'), isNull);
    });

    testWidgets('after login: choose account only with 2+ accounts', (t) async {
      final fam = AccountFamily.instance;
      var asked = 0;
      fam.call = (body) async => {
        'accounts': [
          {'uid': 'u1', 'username': 'main'},
          {'uid': 'u2', 'username': 'second'},
        ],
      };
      late BuildContext ctx;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      );
      fam.askAfterLogin = true;
      await t.runAsync(
        () => afterLoginChoice(
          ctx,
          'u1',
          choose: (l) async {
            asked++;
            expect(l.length, 2);
            return 'u1'; // stay
          },
        ),
      );
      expect(asked, 1);
      expect(fam.askAfterLogin, isFalse);
      // not asked again, and not when only one account
      await t.runAsync(
        () => afterLoginChoice(
          ctx,
          'u1',
          choose: (l) async {
            asked++;
            return null;
          },
        ),
      );
      fam.call = (body) async => {
        'accounts': [
          {'uid': 'u1', 'username': 'main'},
        ],
      };
      fam.askAfterLogin = true;
      await t.runAsync(
        () => afterLoginChoice(
          ctx,
          'u1',
          choose: (l) async {
            asked++;
            return null;
          },
        ),
      );
      expect(asked, 1);
    });

    testWidgets('new account sheet: create only with a free username', (
      t,
    ) async {
      (String, String)? got;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                got = await showModalBottomSheet<(String, String)>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => NewLinkedAccountSheet(
                    usernameCheck: (n) async => n != 'taken',
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      FilledButton btn() =>
          t.widget<FilledButton>(find.byKey(const ValueKey('linked-create')));
      expect(btn().onPressed, isNull);
      await t.enterText(find.byKey(const ValueKey('linked-username')), 'taken');
      await t.pump(const Duration(milliseconds: 600));
      await t.pump();
      expect(
        find.byKey(const ValueKey('username-status-taken')),
        findsOneWidget,
      );
      expect(btn().onPressed, isNull);
      await t.enterText(
        find.byKey(const ValueKey('linked-username')),
        'Fresh.Name',
      );
      await t.pump(const Duration(milliseconds: 600));
      await t.pump();
      expect(
        find.byKey(const ValueKey('username-status-free')),
        findsOneWidget,
      );
      await t.enterText(find.byKey(const ValueKey('linked-name')), 'Fresh');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('linked-create')));
      await t.pumpAndSettle();
      expect(got, ('fresh.name', 'Fresh'));
    });
  });

  // ==================================================== username at signup
  group('username check', () {
    testWidgets('bad / checking / free / taken / offline', (t) async {
      final ctrl = TextEditingController();
      final states = <UsernameState>[];
      await t.pumpWidget(
        _app(
          UsernameStatus(
            controller: ctrl,
            onState: states.add,
            check: (n) async {
              if (n == 'boom') throw Exception('offline');
              return n != 'taken';
            },
          ),
        ),
      );
      ctrl.text = 'a!';
      await t.pump();
      expect(find.byKey(const ValueKey('username-status-bad')), findsOneWidget);
      ctrl.text = 'Taken';
      await t.pump();
      expect(states.last, UsernameState.checking);
      await t.pump(const Duration(milliseconds: 500));
      await t.pump();
      expect(
        find.byKey(const ValueKey('username-status-taken')),
        findsOneWidget,
      );
      ctrl.text = 'free_one';
      await t.pump(const Duration(milliseconds: 500));
      await t.pump();
      expect(
        find.byKey(const ValueKey('username-status-free')),
        findsOneWidget,
      );
      ctrl.text = 'boom';
      await t.pump(const Duration(milliseconds: 500));
      await t.pump();
      expect(states.last, UsernameState.offline);
      expect(kUsernamePattern.hasMatch('ok.name_1'), isTrue);
      expect(kUsernamePattern.hasMatch('no'), isFalse);
    });
  });

  // ================================================================ calls
  group('flip camera', () {
    test(
      'the result is the NEW side (false = back camera, not a failure)',
      () async {
        expect(
          await CallSession.quickSwitchResult(
            () async => false,
            wasFront: true,
          ),
          isFalse,
        );
        expect(
          await CallSession.quickSwitchResult(
            () async => true,
            wasFront: false,
          ),
          isTrue,
        );
        // error -> null (then the camera is reopened)
        expect(
          await CallSession.quickSwitchResult(
            () async => throw Exception('no'),
            wasFront: true,
          ),
          isNull,
        );
        // hangs -> assume it switched
        expect(
          await CallSession.quickSwitchResult(
            () => Completer<bool>().future,
            wasFront: true,
            wait: const Duration(milliseconds: 20),
          ),
          isFalse,
        );
      },
    );
  });

  // =========================================================== chat theme
  group('chat theme stays', () {
    test('phone copy wins, lime removes', () {
      expect(
        ChatPrefsData.mergeThemes(
          {'a': 'ocean', 'b': 'rose'},
          {'b': 'lime', 'c': 'night'},
        ),
        {'a': 'ocean', 'c': 'night'},
      );
    });
  });

  // ========================================================== live photos
  group('profile photo everywhere', () {
    test('new photo shows at once; unknown = saved one', () {
      final lp = LivePhotos.instance;
      expect(lp.urlFor('', 'old'), 'old');
      lp.put('u9', 'https://new');
      expect(lp.urlFor('u9', 'https://old'), 'https://new');
    });
  });

  // ========================================================= link sticker
  group('link stickers', () {
    test('clean addresses', () {
      expect(MediaLink.clean('example.com/a'), 'https://example.com/a');
      expect(MediaLink.clean('http://x.org'), 'http://x.org');
      expect(MediaLink.clean('javascript:alert(1)'), isNull);
      expect(MediaLink.clean('ftp://x.org'), isNull);
      expect(MediaLink.clean('no spaces.com x'), isNull);
      expect(MediaLink.clean('localhost'), isNull);
      expect(MediaLink.clean(''), isNull);
      expect(MediaLink.max, 3);
    });

    test('save / read', () {
      const l = MediaLink(
        url: 'https://www.shop.in/x',
        label: '',
        x: 0.25,
        y: 0.75,
      );
      expect(l.host, 'shop.in');
      expect(l.shown, 'shop.in');
      final back = MediaLink.fromMap(l.toMap());
      expect(back?.url, l.url);
      expect(back?.x, 0.25);
      expect(MediaLink.fromMap({'u': 'javascript:x'}), isNull);
      final far = MediaLink.fromMap({
        'u': 'a.com',
        'x': 5,
        'y': -1,
        'l': 'L' * 80,
      });
      expect(far?.x, 1.0);
      expect(far?.y, 0.0);
      expect(far?.label.length, MediaLink.maxLabel);
    });

    testWidgets('tap a sticker opens its link', (t) async {
      final opened = <String>[];
      await t.pumpWidget(
        _app(
          SizedBox(
            width: 300,
            height: 300,
            child: MediaLinksLayer(
              aspect: 1,
              links: const [
                MediaLink(url: 'https://a.com', label: 'Shop', x: 0.2, y: 0.2),
                MediaLink(url: 'https://b.com', x: 0.8, y: 0.8),
              ],
              onOpen: (context, link) => opened.add(link.url),
            ),
          ),
        ),
      );
      expect(find.text('Shop'), findsOneWidget);
      expect(find.text('b.com'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('media-link-1')));
      expect(opened, ['https://b.com']);
    });
  });

  // ======================================================== edited covers
  group('edits on the share screen + cover', () {
    test('texts shown at a time', () {
      const a = VideoOverlay(kind: 'text', text: 'A', startMs: 0, endMs: 1000);
      const b = VideoOverlay(kind: 'text', text: 'B', startMs: 500, endMs: 0);
      expect(overlaysAt(const [a, b], 100).map((o) => o.text), ['A']);
      expect(overlaysAt(const [a, b], 700).map((o) => o.text), ['A', 'B']);
      expect(overlaysAt(const [a, b], 5000).map((o) => o.text), ['B']);
    });

    test('cover size keeps the shape, max 1080 wide', () {
      expect(coverSize(1920, 16 / 9), const Size(1080, 608));
      expect(coverSize(720, 9 / 16), const Size(720, 1280));
      expect(coverSize(0, 1), const Size(1, 1));
    });
  });

  // ============================================================== replies
  group('hide replies at the top', () {
    setUp(() => CommentTile.debugLiked = (id) => Stream.value(false));
    tearDown(() => CommentTile.debugLiked = null);

    testWidgets('top "Hide replies" closes them', (t) async {
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
      expect(find.byKey(const ValueKey('hide-replies-top-c1')), findsNothing);
      await t.tap(find.byKey(const ValueKey('more-replies-c1')));
      await t.pump();
      expect(find.byKey(const ValueKey('comment-r3')), findsOneWidget);
      final top = find.byKey(
        const ValueKey('hide-replies-top-c1'),
        skipOffstage: false,
      );
      expect(top, findsOneWidget);
      await t.ensureVisible(top);
      await t.pump();
      await t.tap(top);
      await t.pump();
      expect(find.byKey(const ValueKey('comment-r1')), findsNothing);
      expect(find.byKey(const ValueKey('hide-replies-top-c1')), findsNothing);
      await ctrl.close();
    });
  });
}

/// Real async work (SharedPreferences) inside a plain test.
Future<void> runReal(Future<void> Function() f) => f();
