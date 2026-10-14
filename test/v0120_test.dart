import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/services/calls.dart';
import 'package:instantgram/core/services/chat_prefs.dart';
import 'package:instantgram/core/services/content_filter.dart';
import 'package:instantgram/core/services/media_service.dart';
import 'package:instantgram/core/services/saved_accounts.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/chats/presentation/message_widgets.dart';
import 'package:instantgram/features/editor/edit_models.dart';
import 'package:instantgram/features/notifications/presentation/notifications_screen.dart';
import 'package:instantgram/features/settings/presentation/accounts_screen.dart';
import 'package:instantgram/features/settings/presentation/notification_settings_screen.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/models/user_profile.dart';
import 'package:instantgram/shared/widgets/follow_chip.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:instantgram/shared/widgets/video_extras.dart';
import 'package:shared_preferences/shared_preferences.dart';

// v0.12: follow chip, blue ticks, stream fix, notifications, accounts,
// editor maths (split, cuts, texts, voice over).

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark,
  home: Scaffold(body: child),
);

AppNotification _n(String type, {String text = ''}) => AppNotification(
  id: 'n1',
  type: type,
  fromUid: 'u1',
  fromUsername: 'ana',
  fromPhotoUrl: '',
  postId: 'p1',
  postThumb: '',
  text: text,
  read: false,
  createdAt: DateTime(2026, 10, 14),
);

void main() {
  setUpAll(() {
    NetImage.disableCache = true;
    VoiceTrack.disabled = true;
  });

  group('follow chip', () {
    testWidgets('shows Follow, hides after tap', (t) async {
      var taps = 0;
      await t.pumpWidget(
        _app(
          FollowChip(
            targetUid: 'ana',
            myUid: 'me',
            following: Stream.value(false),
            requested: Stream.value(false),
            onFollow: () async => taps++,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('follow-chip')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('follow-chip')));
      await t.pumpAndSettle();
      expect(taps, 1);
      expect(find.byKey(const ValueKey('follow-chip')), findsNothing);
      // v0.13: shows "Following" after the tap
      expect(find.byKey(const ValueKey('follow-following')), findsOneWidget);
    });

    testWidgets('no Follow when following (v0.13: Following) or own clip', (t) async {
      await t.pumpWidget(
        _app(
          Column(
            children: [
              FollowChip(
                targetUid: 'ana',
                myUid: 'me',
                following: Stream.value(true),
                requested: Stream.value(false),
              ),
              FollowChip(
                targetUid: 'me',
                myUid: 'me',
                following: Stream.value(false),
                requested: Stream.value(false),
              ),
            ],
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('follow-chip')), findsNothing);
      expect(find.byKey(const ValueKey('follow-following')), findsOneWidget);
    });
  });

  test('seen ticks are blue', () {
    expect(TickIcon.seenColor(onDark: true), const Color(0xFF34B7F1));
    expect(TickIcon.seenColor(onDark: false), const Color(0xFF0B5FD0));
  });

  test('ring check explains the Vercel key', () {
    final a = CallsText.notSetUp(
      'Calls is not set up: FIREBASE_SERVICE_ACCOUNT is not set on Vercel',
    );
    expect(a, startsWith('Calls is not set up: FIREBASE_SERVICE_ACCOUNT'));
    expect(a, contains('Redeploy'));
    expect(CallsText.notSetUp('x'), contains('missing or wrong'));
  });

  test('profile lists: a stream can be listened twice (no Bad state)', () async {
    ContentFilter.instance.debugSet(me: 'me');
    final src = StreamController<List<int>>.broadcast();
    final s = ContentFilter.instance.watch<int>(src.stream, (x) => x.isEven);
    final a = <List<int>>[], b = <List<int>>[];
    final s1 = s.listen(a.add);
    src.add([1, 2, 3, 4]);
    await Future<void>.delayed(Duration.zero);
    final s2 = s.listen(b.add); // used to crash
    await Future<void>.delayed(Duration.zero);
    expect(a.last, [2, 4]);
    expect(b, isNotEmpty);
    unawaited(s1.cancel());
    unawaited(s2.cancel());
  });

  test('notification texts and view steps', () {
    expect(notificationText(_n(AppNotification.like)), 'liked your post.');
    expect(
      notificationText(_n(AppNotification.commentLike, text: 'hi')),
      'liked your comment: hi',
    );
    expect(notificationText(_n(AppNotification.unfollow)), 'unfollowed you.');
    expect(
      notificationText(_n(AppNotification.views, text: '1000')),
      contains('1K views'),
    );
    expect(compactViews(999), '999');
    expect(compactViews(1500), '1.5K');
    expect(compactViews(10000), '10K');
    expect(compactViews(2000000), '2M');
    expect(ViewMilestones.reached(99), 0);
    expect(ViewMilestones.reached(1200), 1000);
    expect(ViewMilestones.needsCheck(1200, 500), isTrue);
    expect(ViewMilestones.needsCheck(1200, 1000), isFalse);
  });

  testWidgets('Settings -> Notifications switches', (t) async {
    ChatPrefs.instance.debugSet(const ChatPrefsData(pushOff: {'likes'}));
    final calls = <String>[];
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: NotificationSettingsScreen(
          onChanged: (k, on) async => calls.add('$k=$on'),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('push-likes')), findsOneWidget);
    expect(find.byKey(const ValueKey('push-views')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('push-likes')));
    await t.pumpAndSettle();
    expect(calls, ['likes=true']);
    expect(
      ChatPrefsData.fromMap({
        'pushOff': ['views'],
      }).pushOn('views'),
      isFalse,
    );
    ChatPrefs.instance.debugSet(ChatPrefsData.empty);
  });

  group('accounts', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SavedAccounts.instance.debugReset();
    });

    test('remember, password, remove', () async {
      final s = SavedAccounts.instance;
      await s.rememberLogin(uid: 'a1', email: 'a@x.com', password: 'pw1');
      await s.rememberLogin(uid: 'b2', email: 'b@x.com', password: 'pässwörd');
      expect((await s.load()).map((a) => a.uid), ['a1', 'b2']);
      expect(await s.password('b2'), 'pässwörd');
      final raw = (await SharedPreferences.getInstance()).getString(
        'acct_pw_b2',
      );
      expect(raw, isNot(contains('pässwörd')));
      await s.remove('a1');
      expect((await s.load()).map((a) => a.uid), ['b2']);
      const key = [1, 2, 3, 4];
      expect(
        SavedAccounts.unscramble(SavedAccounts.scramble('hello', key), key),
        'hello',
      );
    });

    testWidgets('switch and add', (t) async {
      final s = SavedAccounts.instance;
      await t.runAsync(() async {
        await s.rememberLogin(uid: 'me1', email: 'me@x.com', password: 'p');
        await s.rememberLogin(uid: 'bo2', email: 'bo@x.com', password: 'p');
      });
      SavedAccount? switched;
      var added = 0;
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: AccountsScreen(
            profile: const UserProfile(
              uid: 'me1',
              name: 'Me',
              username: 'me',
              email: 'me@x.com',
            ),
            onSwitch: (a) async => switched = a,
            onAdd: () async => added++,
          ),
        ),
      );
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('account-current')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('account-bo2')));
      await t.pumpAndSettle();
      expect(switched?.uid, 'bo2');
      await t.tap(find.byKey(const ValueKey('account-add')));
      await t.pumpAndSettle();
      expect(added, 1);
    });
  });

  group('video time (split / cuts)', () {
    const cuts = [VideoCut(2000, 3000), VideoCut(5000, 6000)];

    test('normalize, skip, played length, mapping', () {
      expect(
        VideoTime.normalize(const [
          VideoCut(5, 9),
          VideoCut(1, 3),
          VideoCut(2, 6),
          VideoCut(7, 7),
        ]),
        const [VideoCut(1, 9)],
      );
      expect(VideoTime.skipTo(2500, cuts), 3000);
      expect(VideoTime.skipTo(4000, cuts), isNull);
      expect(VideoTime.firstPlayable(2000, cuts), 3000);
      expect(VideoTime.playableEnd(6000, cuts), 5000);
      expect(VideoTime.playableEnd(8000, cuts), 8000);
      expect(VideoTime.playedMs(0, 8000, cuts), 6000);
      expect(VideoTime.playedAt(4000, 0, cuts), 3000);
      expect(VideoTime.sourceAt(3000, 0, cuts), 4000);
      expect(VideoTime.sourceAt(4500, 0, cuts), 6500);
    });

    test('edits save and load (voice file never published)', () {
      const e = VideoEdits(
        trimStartMs: 500,
        muted: true,
        cuts: cuts,
        overlays: [
          VideoOverlay(kind: VideoOverlay.textKind, text: 'Hi', endMs: 4000),
          VideoOverlay(kind: VideoOverlay.stickerKind, text: '🔥', size: 0.16),
        ],
        voicePath: '/data/voiceover_1.m4a',
        voiceStartMs: 1000,
        voiceDurMs: 2500,
      );
      final pub = e.withVoice('https://x/v.m4a', 'k/v.m4a').toMap();
      expect(pub.containsKey('voicePath'), isFalse);
      final back = VideoEdits.fromMap(pub);
      expect(back.cuts, cuts);
      expect(back.overlays.length, 2);
      expect(back.overlays[1].isSticker, isTrue);
      expect(back.overlays[0].visibleAt(4000), isFalse);
      expect(back.voiceUrl, 'https://x/v.m4a');
      expect(back.voiceDurMs, 2500);
      expect(e.withoutVoice().hasVoice, isFalse);
      expect(VoiceTrack.voiceAt(back, 1000), isNull); // played 500
      expect(VoiceTrack.voiceAt(back, 1600), 100); // played 1100
    });

    test('editor parts: split, delete part, played length', () {
      final item = EditItem(
        PickedMedia(File('v.mp4'), isVideo: true),
        mode: ComposeMode.clip,
      )..durationMs = 10000;
      item.splits.addAll([3000, 6000]);
      expect(item.segments.length, 3);
      final mid = item.segmentAt(4000)!;
      item.cuts = [mid];
      expect(item.isCut(mid), isTrue);
      expect(item.playedMs, 7000);
      item.trimStart = 4000;
      expect(item.activeCuts, const [VideoCut(4000, 6000)]);
      expect(item.playedMs, 4000);
      expect(item.videoEdits.cuts, const [VideoCut(4000, 6000)]);
    });
  });
}
