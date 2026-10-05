import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/app_info.dart';
import 'package:instantgram/core/l10n.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/screens/settings/app_screens.dart';
import 'package:instantgram/screens/settings/settings_screen.dart';
import 'package:instantgram/services/app_prefs.dart';
import 'package:instantgram/services/auth_service.dart';
import 'package:instantgram/services/safety_service.dart';
import 'package:instantgram/widgets/like_button.dart';
import 'package:instantgram/widgets/reel_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

Post _post({
  String author = 'other',
  String audience = kAudienceEveryone,
  bool authorPrivate = false,
  bool hideLikes = false,
}) => Post(
  id: 'p1',
  authorId: author,
  authorUsername: 'someone',
  authorPhotoUrl: '',
  type: 'image',
  caption: 'hello',
  createdAt: DateTime(2026, 1, 1),
  audience: audience,
  authorPrivate: authorPrivate,
  hideLikes: hideLikes,
);

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.light,
  darkTheme: AppTheme.dark,
  home: LanguageScope(language: Language.instance, child: child),
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppPrefs.instance.init();
    Language.instance.choose('en');
    SafetyService.instance.clear();
  });

  group('versions', () {
    test('a higher version is newer, the same or lower is not', () {
      expect(isNewerVersion('v1.14.0', '1.13.0'), isTrue);
      expect(isNewerVersion('1.13.1', '1.13.0'), isTrue);
      expect(isNewerVersion('2.0.0', '1.99.9'), isTrue);
      expect(isNewerVersion('v1.13.0', '1.13.0'), isFalse);
      expect(isNewerVersion('1.12.9', '1.13.0'), isFalse);
      expect(isNewerVersion('nonsense', '1.13.0'), isFalse);
    });
  });

  group('age gate', () {
    test('under 13 is refused, 13 and older is fine', () {
      final today = DateTime(2026, 10, 5);
      expect(AuthService.isOldEnough(DateTime(2013, 10, 6), today), isFalse);
      expect(AuthService.isOldEnough(DateTime(2013, 10, 5), today), isTrue);
      expect(AuthService.isOldEnough(DateTime(1990, 1, 1), today), isTrue);
      expect(AuthService.isOldEnough(DateTime(2020, 1, 1), today), isFalse);
    });
  });

  group('language', () {
    test('a chosen language translates and is remembered', () {
      expect(Language.instance.translate('Settings'), 'Settings');
      Language.instance.choose('hi');
      expect(Language.instance.translate('Settings'), 'सेटिंग्स');
      expect(AppPrefs.instance.language, 'hi');
      expect(Language.instance.translate('no such text'), 'no such text');
      Language.instance.choose('xx');
      expect(Language.instance.value, 'en');
    });

    test('every language knows the same words', () {
      for (final l in kLanguages.where((l) => l.code != 'en')) {
        Language.instance.choose(l.code);
        expect(Language.instance.translate('Posts') != 'Posts', isTrue,
            reason: l.code);
        expect(Language.instance.translate('Block') != 'Block', isTrue,
            reason: l.code);
      }
    });
  });

  group('prefs', () {
    test('history keeps the newest first, once per post', () {
      AppPrefs.instance.addHistory('a');
      AppPrefs.instance.addHistory('b');
      AppPrefs.instance.addHistory('a');
      expect([for (final e in AppPrefs.instance.history) e.postId], ['a', 'b']);
      AppPrefs.instance.removeHistory('a');
      expect([for (final e in AppPrefs.instance.history) e.postId], ['b']);
    });

    test('screen time adds up per day', () {
      final d = DateTime(2026, 10, 5);
      AppPrefs.instance.addUsage(d, 30);
      AppPrefs.instance.addUsage(d, 45);
      expect(AppPrefs.instance.usageSeconds(d), 75);
      expect(AppPrefs.instance.usageSeconds(DateTime(2026, 10, 4)), 0);
    });

    test('accessibility values are kept and kept in range', () {
      AppPrefs.instance.textScale = 5;
      expect(AppPrefs.instance.textScale, 1.6);
      AppPrefs.instance.boldText = true;
      expect(AppPrefs.instance.boldText, isTrue);
    });
  });

  group('post options', () {
    test('they are written to the post and read back', () {
      const o = PostOptions(
        audience: kAudienceFollowers,
        hideLikes: true,
        hideShares: true,
      );
      final m = o.toMap();
      expect(m['audience'], 'followers');
      expect(m['hideLikes'], true);
      expect(m['hideComments'], false);
      expect(m['shareCount'], 0);
    });
  });

  group('who can see a post', () {
    test('everyone sees public posts; my own posts always', () {
      SafetyService.instance.me = 'me';
      expect(SafetyService.instance.canSee(_post()), isTrue);
      expect(
        SafetyService.instance.canSee(
          _post(author: 'me', audience: kAudienceMe),
        ),
        isTrue,
      );
    });

    test('only me, followers-only and private accounts are enforced', () {
      SafetyService.instance.me = 'me';
      expect(
        SafetyService.instance.canSee(_post(audience: kAudienceMe)),
        isFalse,
      );
      expect(
        SafetyService.instance.canSee(_post(audience: kAudienceFollowers)),
        isFalse,
      );
      expect(
        SafetyService.instance.canSee(_post(authorPrivate: true)),
        isFalse,
      );
      SafetyService.instance.following = {'other'};
      expect(
        SafetyService.instance.canSee(_post(audience: kAudienceFollowers)),
        isTrue,
      );
      expect(SafetyService.instance.canSee(_post(authorPrivate: true)), isTrue);
    });

    test('blocked people disappear', () {
      SafetyService.instance.me = 'me';
      SafetyService.instance.blocked.value = {'other'};
      expect(SafetyService.instance.canSee(_post()), isFalse);
      expect(SafetyService.instance.visible([_post()]), isEmpty);
    });

    test('hidden counts are shown to the author only', () {
      SafetyService.instance.me = 'me';
      final p = _post(hideLikes: true);
      expect(SafetyService.instance.showsNumber(p, p.hideLikes), isFalse);
      final mine = _post(author: 'me', hideLikes: true);
      expect(SafetyService.instance.showsNumber(mine, mine.hideLikes), isTrue);
      expect(SafetyService.instance.showsNumber(p, false), isTrue);
    });
  });

  group('heart button', () {
    testWidgets('the count can be hidden', (t) async {
      final c = LikeController('p1', 12);
      await t.pumpWidget(
        _app(Scaffold(body: HeartButton(controller: c, showCount: false))),
      );
      expect(find.text('12'), findsNothing);
      await t.pumpWidget(
        _app(Scaffold(body: HeartButton(controller: c))),
      );
      expect(find.text('12'), findsOneWidget);
    });
  });

  group('report', () {
    test('the reason and the written problem are in the email', () {
      final u = reportUri(
        _post(),
        reason: 'Spam',
        details: 'It sells things',
      ).toString();
      expect(u, startsWith('mailto:techlabs.hyper@gmail.com'));
      expect(u, contains('Spam'));
      expect(u, contains('It%20sells%20things'));
    });

    testWidgets('Send stays off until the problem is written', (t) async {
      await t.pumpWidget(
        _app(
          Builder(
            builder: (c) => Scaffold(
              body: TextButton(
                onPressed: () => showReportSheet(c, _post()),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      FilledButton send() =>
          t.widget<FilledButton>(find.byKey(const ValueKey('reportSend')));
      expect(send().onPressed, isNull);
      await t.enterText(find.byKey(const ValueKey('reportText')), 'bad clip');
      await t.pump();
      expect(send().onPressed, isNotNull);
    });
  });

  group('settings', () {
    testWidgets('search narrows the list', (t) async {
      t.view.physicalSize = const Size(800, 3000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(const SettingsScreen()));
      expect(find.byKey(const ValueKey('setting_language')), findsOneWidget);
      expect(find.byKey(const ValueKey('setting_blocked')), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('settingsSearch')), 'hindi');
      await t.pump();
      expect(find.byKey(const ValueKey('setting_language')), findsOneWidget);
      expect(find.byKey(const ValueKey('setting_blocked')), findsNothing);
      await t.enterText(find.byKey(const ValueKey('settingsSearch')), 'zzzzz');
      await t.pump();
      expect(find.textContaining('No setting matches'), findsOneWidget);
    });

    testWidgets('choosing a language changes the words', (t) async {
      await t.pumpWidget(_app(const SettingsScreen()));
      expect(find.text('Settings'), findsOneWidget);
      Language.instance.choose('hi');
      await t.pumpAndSettle();
      expect(find.text('सेटिंग्स'), findsWidgets);
    });
  });

  group('app update screen', () {
    tearDown(() => AppUpdateScreen.fetcher = null);

    testWidgets('a newer release offers the download', (t) async {
      AppUpdateScreen.fetcher = () async => {
        'tag_name': 'v9.0.0',
        'body': 'Big things',
        'html_url': 'https://example.com/r',
        'assets': [
          {
            'name': 'app.apk',
            'browser_download_url': 'https://example.com/app.apk',
          },
        ],
      };
      await t.pumpWidget(_app(const AppUpdateScreen()));
      await t.pumpAndSettle();
      expect(find.textContaining('9.0.0'), findsWidgets);
      expect(find.textContaining('Big things'), findsOneWidget);
    });

    testWidgets('no release says so', (t) async {
      AppUpdateScreen.fetcher = () async => null;
      await t.pumpWidget(_app(const AppUpdateScreen()));
      await t.pumpAndSettle();
      expect(find.textContaining('No newer version'), findsOneWidget);
    });

    testWidgets('a failed check is explained', (t) async {
      AppUpdateScreen.fetcher = () async => throw Exception('offline');
      await t.pumpWidget(_app(const AppUpdateScreen()));
      await t.pumpAndSettle();
      expect(find.textContaining('Could not check'), findsOneWidget);
    });
  });
}
