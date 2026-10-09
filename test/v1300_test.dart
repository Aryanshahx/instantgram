import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/errors.dart';
import 'package:instantgram/core/l10n.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/app_notification.dart';
import 'package:instantgram/models/app_user.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/models/story.dart';
import 'package:instantgram/screens/auth/login_screen.dart';
import 'package:instantgram/services/account_vault.dart';
import 'package:instantgram/services/app_prefs.dart';
import 'package:instantgram/services/auth_service.dart';
import 'package:instantgram/services/daily_stats.dart';
import 'package:instantgram/services/report_service.dart';
import 'package:instantgram/services/safety_service.dart';
import 'package:instantgram/widgets/moment_open.dart';
import 'package:shared_preferences/shared_preferences.dart';

Post _post({int reports = 0, bool hidden = false, String author = 'other1'}) =>
    Post(
      id: 'p1',
      authorId: author,
      authorUsername: 'other',
      authorPhotoUrl: '',
      type: 'image',
      caption: 'hi',
      createdAt: DateTime(2026, 1, 1),
      reportCount: reports,
      hidden: hidden,
    );

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark,
  home: LanguageScope(language: Language.instance, child: child),
);

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppPrefs.instance.init();
    Language.instance.choose('en');
    AccountVault.instance.debugStore = {};
    debugDailySink = null;
    debugMomentGroups = null;
    debugOpenMoments = null;
    debugReportSink = null;
  });
  tearDown(() {
    AccountVault.instance.debugStore = null;
    AuthService.instance.debugSwitch = null;
    SafetyService.instance.clear();
  });

  group('switch accounts without the password', () {
    test('the vault keeps, reads and forgets logins', () async {
      final v = AccountVault.instance;
      await v.save('u1', 'a@x.com', 'pw1');
      await v.save('u2', 'b@x.com', 'pw2');
      await v.save('u3', '', 'nope'); // incomplete: ignored
      expect(await v.uids(), {'u1', 'u2'});
      expect(await v.read('u1'), ('a@x.com', 'pw1'));
      await v.forget('u1');
      expect(await v.read('u1'), isNull);
      expect(v.debugStore!.values.single, isNot(contains('a@x.com')));
    });

    test('a broken store means "no saved logins"', () async {
      AccountVault.instance.debugStore = {'ig_logins_v1': '{not json'};
      expect(await AccountVault.instance.uids(), isEmpty);
    });

    testWidgets('the login screen offers one-tap login for saved accounts', (
      t,
    ) async {
      AppPrefs.instance.rememberAccount(
        const SavedAccount(uid: 'u7', username: 'zoe', photoUrl: '', email: ''),
      );
      AppPrefs.instance.rememberAccount(
        const SavedAccount(uid: 'u8', username: 'max', photoUrl: '', email: ''),
      );
      await AccountVault.instance.save('u7', 'z@x.com', 'pw');
      final asked = <String>[];
      AuthService.instance.debugSwitch = (uid) async {
        asked.add(uid);
        return true;
      };
      await t.pumpWidget(_app(const LoginScreen()));
      await _settle(t);
      expect(find.text('Continue as @zoe'), findsOneWidget);
      expect(find.text('Continue as @max'), findsNothing); // no saved login
      await t.tap(find.byKey(const ValueKey('continueAs_u7')));
      await _settle(t);
      expect(asked, ['u7']);
    });

    test('blocked emails get a clear message', () {
      expect(
        friendlyError(const EmailBlockedException()),
        contains('cannot be used'),
      );
    });
  });

  group('admin panel results in the app', () {
    test('a timed suspension ends by itself', () {
      final now = DateTime.now();
      expect(
        const AppUser(uid: 'a', username: 'a', banned: true).suspended,
        isTrue,
      );
      expect(
        AppUser(
          uid: 'a',
          username: 'a',
          banned: true,
          bannedUntil: now.add(const Duration(days: 2)),
        ).suspended,
        isTrue,
      );
      expect(
        AppUser(
          uid: 'a',
          username: 'a',
          banned: true,
          bannedUntil: now.subtract(const Duration(minutes: 1)),
        ).suspended,
        isFalse,
      );
      expect(const AppUser(uid: 'a', username: 'a').suspended, isFalse);
    });

    test('team messages and warnings read right', () {
      const msg = AppNotification(
        id: 'n1',
        type: 'admin',
        title: 'New stickers',
        text: 'Try them',
      );
      const warn = AppNotification(id: 'n2', type: 'warning', text: 'Stop');
      expect(msg.isFromTeam, isTrue);
      expect(msg.verb, 'New stickers');
      expect(warn.isFromTeam, isTrue);
      expect(warn.verb, 'Warning');
      expect(const AppNotification(id: 'x', type: 'like').isFromTeam, isFalse);
    });

    test(
      'hidden and much-reported posts are not shown (but to the author)',
      () {
        final s = SafetyService.instance..me = 'me1';
        expect(s.canSee(_post(reports: 9)), isTrue); // auto-hide off
        s.autoHide = 3;
        expect(s.canSee(_post(reports: 2)), isTrue);
        expect(s.canSee(_post(reports: 3)), isFalse);
        expect(s.canSee(_post(hidden: true)), isFalse);
        expect(s.canSee(_post(hidden: true, author: 'me1')), isTrue);
      },
    );

    test('active people are counted once a day', () async {
      final days = <String>[];
      debugDailySink = days.add;
      final t = DateTime.utc(2026, 10, 9, 10);
      await countActiveToday('u1', now: t);
      await countActiveToday('u1', now: t.add(const Duration(hours: 3)));
      await countActiveToday('u1', now: t.add(const Duration(days: 1)));
      expect(days, ['2026-10-09', '2026-10-10']);
      expect(statsDay(DateTime.utc(2026, 1, 5)), '2026-01-05');
    });

    test('a chat report names the chat', () async {
      final saved = <Map<String, Object?>>[];
      debugReportSink = (d) async => saved.add(d);
      final ok = await sendChatReport(
        chatId: 'a_b',
        otherUid: 'b',
        otherUsername: 'bob',
        text: 'rude',
      );
      expect(ok, isTrue);
      expect(saved.single['kind'], 'chat');
      expect(saved.single['chatId'], 'a_b');
      expect(saved.single['ownerId'], 'b');
    });
  });

  group('moments from the profile picture', () {
    StoryGroup group(String uid) => StoryGroup(
      authorId: uid,
      username: uid,
      photoUrl: '',
      stories: [
        Story(
          id: 's_$uid',
          authorId: uid,
          username: uid,
          photoUrl: '',
          imageRef: 'x',
          createdAt: DateTime(2026, 1, 1),
        ),
      ],
    );

    testWidgets('a person with a moment opens it; without, nothing', (t) async {
      debugMomentGroups = () async => [group('a'), group('b')];
      StoryGroup? opened;
      debugOpenMoments = (g) => opened = g;
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
      expect(await openMomentsOf(ctx, 'b'), isTrue);
      expect(opened!.authorId, 'b');
      opened = null;
      expect(await openMomentsOf(ctx, 'zzz'), isFalse);
      expect(opened, isNull);
    });
  });

  group('source checks', () {
    test('no App update setting any more', () {
      final s = File(
        'lib/screens/settings/settings_screen.dart',
      ).readAsStringSync();
      expect(s, isNot(contains("'App update'")));
    });

    test('Follow and Message are the same size on profiles', () {
      final s = File(
        'lib/screens/profile/profile_screen.dart',
      ).readAsStringSync();
      expect(s, contains('style: _smallButton'));
      expect(
        RegExp(r'height: 38').allMatches(s).length,
        greaterThanOrEqualTo(2),
      );
      expect(s, contains("ValueKey('profileAvatar')"));
    });

    test('rules: blocked emails, report counts, daily stats', () {
      final r = File('firebase/firestore.rules').readAsStringSync();
      expect(r, contains('match /blockedEmails/{email}'));
      expect(r, contains('match /reporters/{uid}'));
      expect(r, contains('match /dailyStats/{day}'));
      expect(r, contains('match /config/{doc}'));
      expect(r, contains("hasAny(['verified', 'bannedUntil', 'warnings'"));
      expect(r, contains("'chatId'"));
    });

    test('the panel has the new tools', () {
      final h = File('signer/lib/panel.html').readAsStringSync();
      for (final s in [
        'data-tab="charts"',
        'data-tab="settings"',
        'id="blockMail"',
        'data-warn',
        'data-suspend',
        'bulkDelete',
        'uploadImage',
        'openChat',
      ]) {
        expect(h, contains(s), reason: s);
      }
    });
  });
}
