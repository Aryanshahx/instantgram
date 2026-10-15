// v0.14 tests: shared disappearing, quick "typing…", verified badges,
// account switcher, instant unfollow, notice pictures, editor parts,
// stickers (animated + search), clips start quality, edge gestures.
import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/services/account_status.dart';
import 'package:instantgram/core/services/gesture_exclusion.dart';
import 'package:instantgram/core/services/media_service.dart';
import 'package:instantgram/core/services/net_quality.dart';
import 'package:instantgram/core/services/saved_accounts.dart';
import 'package:instantgram/core/services/video_cache.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/chats/data/chat_repository.dart';
import 'package:instantgram/features/chats/data/typing_tracker.dart';
import 'package:instantgram/features/editor/edit_models.dart';
import 'package:instantgram/features/notifications/presentation/notifications_screen.dart';
import 'package:instantgram/features/settings/presentation/accounts_screen.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/models/user_profile.dart';
import 'package:instantgram/shared/widgets/follow_chip.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:instantgram/shared/widgets/stickers.dart';
import 'package:instantgram/shared/widgets/verified_badge.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _t0 = DateTime(2026, 10, 15, 10);

Message _msg(
  String id,
  String from, {
  DateTime? at,
  DateTime? expireAt,
  bool vanish = false,
}) => Message(
  id: id,
  senderId: from,
  text: id,
  createdAt: at ?? _t0,
  expireAt: expireAt,
  vanish: vanish,
);

Chat _chat(Map<String, DateTime> typing) => Chat(
  id: 'a_b',
  members: const ['a', 'b'],
  memberInfo: const {},
  lastMessage: '',
  lastSenderId: '',
  updatedAt: _t0,
  typing: typing,
);

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  setUpAll(() => NetImage.disableCache = true);

  group('disappearing messages (both people again)', () {
    test('fields of a new message', () {
      expect(ChatRepository.disappearFields(Disappear.off, _t0), isEmpty);
      expect(ChatRepository.disappearFields(Disappear.seen, _t0), {
        'vanish': true,
      });
      final day = ChatRepository.disappearFields(Disappear.day, _t0);
      expect(
        (day['expireAt'] as Timestamp).toDate(),
        _t0.add(const Duration(hours: 24)),
      );
      final week = ChatRepository.disappearFields(Disappear.week, _t0);
      expect(
        (week['expireAt'] as Timestamp).toDate(),
        _t0.add(const Duration(days: 7)),
      );
    });

    test('a timed message goes away for BOTH people', () {
      final all = [
        _msg('old', 'a', expireAt: _t0.add(const Duration(hours: 1))),
        _msg('keep', 'b'),
      ];
      final later = _t0.add(const Duration(hours: 2));
      for (final me in ['a', 'b']) {
        expect(
          ChatRepository.visible(all, me: me, now: later).map((m) => m.id),
          ['keep'],
          reason: me,
        );
        expect(ChatRepository.visible(all, me: me, now: _t0).map((m) => m.id), [
          'old',
          'keep',
        ]);
      }
    });

    test('"once seen" hides for the reader after seeing it', () {
      final all = [
        _msg('v', 'a', vanish: true),
        _msg(
          'later',
          'a',
          vanish: true,
          at: _t0.add(const Duration(minutes: 1)),
        ),
      ];
      final seen = _t0.add(const Duration(seconds: 30));
      expect(
        ChatRepository.visible(
          all,
          me: 'b',
          seenBefore: seen,
          now: _t0,
        ).map((m) => m.id),
        ['later'],
      );
    });
  });

  group('typing… (quick, any phone clock)', () {
    test('new signal = typing, goes away after 6 s', () {
      var now = _t0;
      final tr = TypingTracker(clock: () => now);
      // the other phone's clock is 10 minutes wrong: still works
      final stamp = _t0.subtract(const Duration(minutes: 10));
      final c = _chat({'b': stamp});
      expect(tr.isTyping(c, 'b', serverNow: stamp), isTrue);
      expect(tr.left(c, 'b'), TypingTracker.show);
      now = now.add(const Duration(seconds: 4));
      expect(tr.isTyping(c, 'b'), isTrue);
      now = now.add(const Duration(seconds: 3));
      expect(tr.isTyping(c, 'b'), isFalse, reason: 'no new signal');
      expect(tr.left(c, 'b'), isNull);
      // a new signal shows it right away
      final c2 = _chat({'b': stamp.add(const Duration(seconds: 3))});
      expect(tr.isTyping(c2, 'b'), isTrue);
      // stopped typing (field removed)
      expect(tr.isTyping(_chat({}), 'b'), isFalse);
      expect(TypingTracker.ping < TypingTracker.show, isTrue);
    });

    test('leftover from long ago is not shown', () {
      final tr = TypingTracker(clock: () => _t0);
      final c = _chat({'b': _t0.subtract(const Duration(minutes: 5))});
      expect(tr.isTyping(c, 'b', serverNow: _t0), isFalse);
      expect(tr.isTyping(c, 'a'), isFalse);
      tr.clear();
    });
  });

  group('verified badge everywhere', () {
    tearDown(() => AccountStatus.instance.debugSetVerified(const {}));

    testWidgets('NameBadge + verifiedSpan', (t) async {
      AccountStatus.instance.debugSetVerified({'v1'});
      await t.pumpWidget(
        _app(
          Column(
            children: [
              const NameBadge('star', uid: 'v1'),
              const NameBadge('normal', uid: 'n1'),
              Text.rich(
                TextSpan(text: 'span ', children: [verifiedSpan('v1')]),
              ),
            ],
          ),
        ),
      );
      expect(find.text('star'), findsOneWidget);
      expect(find.text('normal'), findsOneWidget);
      expect(find.byKey(const ValueKey('verified-badge')), findsNWidgets(2));
      AccountStatus.instance.debugSetVerified(const {});
      await t.pump();
      expect(find.byKey(const ValueKey('verified-badge')), findsNothing);
    });
  });

  group('switch account (Me screen)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SavedAccounts.instance.debugReset();
    });

    testWidgets('sheet: current, others, add', (t) async {
      await t.runAsync(() async {
        final s = SavedAccounts.instance;
        await s.rememberLogin(uid: 'me1', email: 'me@x.com', password: 'p');
        await s.rememberLogin(uid: 'bo2', email: 'bo@x.com', password: 'p');
      });
      const me = UserProfile(
        uid: 'me1',
        name: 'Me',
        username: 'me',
        email: 'me@x.com',
      );
      SavedAccount? switched;
      var added = 0;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () => showAccountSwitcher(
                context,
                me,
                onSwitch: (a) async => switched = a,
                onAdd: () async => added++,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      Future<void> open() async {
        await t.tap(find.byKey(const ValueKey('open')));
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await t.pumpAndSettle();
      }

      await open();
      expect(find.byKey(const ValueKey('switch-current')), findsOneWidget);
      expect(find.byKey(const ValueKey('switch-to-me1')), findsNothing);
      await t.tap(find.byKey(const ValueKey('switch-to-bo2')));
      await t.pumpAndSettle();
      expect(switched?.uid, 'bo2');
      await open();
      await t.tap(find.byKey(const ValueKey('switch-add')));
      await t.pumpAndSettle();
      expect(added, 1);
    });
  });

  group('no pop-ups at the bottom', () {
    testWidgets('tap Following = unfollow at once, no snackbar', (t) async {
      var unfollowed = 0;
      final following = StreamController<bool>();
      await t.pumpWidget(
        _app(
          FollowChip(
            targetUid: 'bo',
            myUid: 'me',
            following: following.stream,
            requested: Stream.value(false),
            onUnfollow: () async => unfollowed++,
          ),
        ),
      );
      following.add(true);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('follow-following')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('follow-following')));
      await t.pump();
      expect(unfollowed, 1);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('follow-chip')), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await following.close();
    });
  });

  group('admin notice with a picture', () {
    AppNotification notice(String thumb) => AppNotification(
      id: 'n1',
      type: AppNotification.notice,
      fromUid: '',
      fromUsername: 'InstantGram',
      fromPhotoUrl: '',
      postId: '',
      postThumb: thumb,
      text: 'New stickers are here!',
      read: false,
      createdAt: _t0,
    );

    Future<void> show(WidgetTester t, AppNotification n) async {
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () => showNotice(context, n),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('open')));
      await t.pumpAndSettle();
    }

    testWidgets('picture shown', (t) async {
      await show(t, notice('https://b.t3.tigrisfiles.io/notice/1.jpg'));
      expect(find.byKey(const ValueKey('notice-image')), findsOneWidget);
      expect(find.text('New stickers are here!'), findsOneWidget);
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
    });

    testWidgets('no picture', (t) async {
      await show(t, notice(''));
      expect(find.byKey(const ValueKey('notice-image')), findsNothing);
      expect(find.byKey(const ValueKey('notice-badge')), findsOneWidget);
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
    });
  });

  group('editor: split parts with their own trim', () {
    EditItem video() => EditItem(
      PickedMedia(File('v.mp4'), isVideo: true),
      mode: ComposeMode.clip,
    )..durationMs = 10000;

    test('split, trim each part, restore, delete', () {
      final e = video();
      expect(e.splitAt(-5), 'Move the white line inside the video.');
      expect(e.splitAt(20000), 'Move the white line inside the video.');
      expect(e.splitAt(100), contains('Too close'));
      expect(e.splitAt(5000), isNull);
      expect(e.segments.length, 2);
      expect(e.splitAt(5100), contains('Too close'));
      final a = e.segments[0], b = e.segments[1];
      expect(e.segmentIndexAt(2000), 0);
      expect(e.segmentIndexAt(7000), 1);
      expect(e.segmentIndexAt(10000), 1);
      expect(e.segmentIndexAt(-1), -1);

      // trim part 1 only
      e.setKept(a, 1000, 4000);
      expect(e.keptOf(a)!.startMs, 1000);
      expect(e.keptOf(a)!.endMs, 4000);
      expect(e.keptOf(b)!.startMs, 5000);
      expect(e.keptOf(b)!.endMs, 10000);
      expect(e.playedMs, 3000 + 5000);

      // trim part 2: part 1 keeps its trim
      e.setKept(b, 6000, 9000);
      expect(e.keptOf(a)!.startMs, 1000);
      expect(e.playedMs, 3000 + 3000);

      // can't make a part shorter than minPartMs
      e.setKept(a, 2000, 2010);
      expect(e.keptOf(a)!.endMs - e.keptOf(a)!.startMs, EditItem.minPartMs);

      // split inside the trimmed part 2
      expect(e.splitAt(7500), isNull);
      expect(e.segments.length, 3);
      expect(e.splitAt(7600), isNotNull);

      // restore part 1 = whole again
      e.restorePart(e.segments[0]);
      expect(e.keptOf(e.segments[0])!.startMs, 0);
      expect(e.keptOf(e.segments[0])!.endMs, 5000);

      // delete a part: no split inside it
      final last = e.segments[2];
      e.cuts = VideoTime.normalize([...e.cuts, last]);
      expect(e.keptOf(last), isNull);
      expect(e.isCut(last), isTrue);
      expect(
        e.splitAt(last.startMs + 600),
        'This part is deleted. Bring it back first.',
      );
      e.restorePart(last);
      expect(e.keptOf(last), isNotNull);
    });

    test('saved edits keep the cuts', () {
      final e = video()..splits.add(5000);
      e.setKept(e.segments[1], 5000, 8000);
      expect(e.videoEdits.cuts.map((c) => [c.startMs, c.endMs]), [
        [8000, 10000],
      ]);
    });
  });

  group('stickers: more, animated, search', () {
    test('pack + files', () {
      final animated = StickerPack.ids.where(StickerPack.isAnimated).toList();
      expect(StickerPack.ids.length, greaterThanOrEqualTo(120));
      expect(animated.length, greaterThanOrEqualTo(30));
      for (final id in StickerPack.ids) {
        final asset = StickerPack.assetFor(StickerPack.textFor(id));
        expect(asset.endsWith(id.startsWith('a_') ? '.webp' : '.png'), isTrue);
        expect(File(asset).existsSync(), isTrue, reason: asset);
      }
      // animated stickers really move (more than one frame)
      final bytes = File('assets/stickers/a_heart.webp').readAsBytesSync();
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WEBP');
      expect(String.fromCharCodes(bytes), contains('ANMF'));
    });

    test('search', () {
      expect(StickerPack.search('fire'), contains('a_fire'));
      expect(StickerPack.search('FIRE'), contains('a_fire'));
      expect(StickerPack.search('love'), contains('a_heart'));
      expect(StickerPack.search('zzqq'), isEmpty);
      expect(StickerPack.search('').length, StickerPack.ids.length);
      final moving = StickerPack.search('', animatedOnly: true);
      expect(moving, isNotEmpty);
      expect(moving.every(StickerPack.isAnimated), isTrue);
    });
  });

  group('clips start fast (like Reels)', () {
    const m = MediaItem(
      url: 'https://x/full-v14.mp4',
      lowUrl: 'https://x/low-v14.mp4',
      isVideo: true,
    );
    tearDown(() {
      Bandwidth.reset();
      NetQuality.reset();
    });

    test('small copy first, full when fast or already saved', () {
      Bandwidth.reset();
      NetQuality.reset();
      expect(NetQuality.urlFor(m), m.lowUrl);
      expect(NetQuality.prefetchBytesFor(m), 2600 * 1024);
      // tiny downloads don't count as a speed test
      Bandwidth.add(100 * 1024, 10);
      expect(Bandwidth.samples, 0);
      expect(NetQuality.urlFor(m), m.lowUrl);
      // slow network stays small
      Bandwidth.add(1024 * 1024, 4000); // ~2 Mbps
      expect(Bandwidth.fast, isFalse);
      expect(NetQuality.urlFor(m), m.lowUrl);
      // the start of the full copy is already on the phone
      VideoCache.instance.debugSetKnown(m.url, NetQuality.fullStartBytes);
      expect(NetQuality.urlFor(m), m.url);
      expect(NetQuality.prefetchBytesFor(m), 3 * 1024 * 1024);
      VideoCache.instance.debugSetKnown(m.url, 0);
      // fast wifi
      Bandwidth.reset();
      Bandwidth.add(4 * 1024 * 1024, 1000);
      expect(Bandwidth.fast, isTrue);
      expect(NetQuality.urlFor(m), m.url);
      // buffering seen = small copy for a while
      NetQuality.markSlow();
      expect(NetQuality.urlFor(m), m.lowUrl);
      expect(
        NetQuality.startTimeout,
        lessThanOrEqualTo(const Duration(milliseconds: 1500)),
      );
    });
  });

  group('editor trim vs the back swipe', () {
    const ch = MethodChannel('instantgram/system');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (c) async {
            calls.add(c);
            return null;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null);
      debugDefaultTargetPlatformOverride = null;
      GestureExclusion.instance.clear();
    });

    test('edge strips sent once, cleared on leave', () {
      final g = GestureExclusion.instance;
      g.set(
        const Rect.fromLTWH(0, 500, 400, 120),
        screenWidth: 400,
        devicePixelRatio: 2,
      );
      g.set(
        const Rect.fromLTWH(0, 500, 400, 120),
        screenWidth: 400,
        devicePixelRatio: 2,
      );
      expect(calls.length, 1);
      expect(calls.single.method, 'gestureExclusion');
      expect((calls.single.arguments as Map)['rects'], [
        0, 1000, 80, 1240, //
        720, 1000, 800, 1240,
      ]);
      g.clear();
      expect(calls.length, 2);
      expect((calls.last.arguments as Map)['rects'], isEmpty);
    });
  });
}
