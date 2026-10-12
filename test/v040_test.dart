import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/config/app_info.dart';
import 'package:instantgram/core/constants/languages.dart';
import 'package:instantgram/core/services/app_settings.dart';
import 'package:instantgram/core/services/content_filter.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/core/utils/email.dart';
import 'package:instantgram/features/post/data/report_repository.dart';
import 'package:instantgram/features/settings/presentation/settings_pages.dart';
import 'package:instantgram/features/settings/presentation/settings_screen.dart';
import 'package:instantgram/features/settings/presentation/time_screen.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/models/user_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

Post _post({String audience = Audience.everyone, String author = 'a1'}) => Post(
  id: 'p1',
  authorId: author,
  authorUsername: 'riya',
  authorPhotoUrl: '',
  type: Post.clip,
  mediaUrl: 'https://x/v.mp4',
  mediaKey: 'k',
  caption: 'hi',
  aspectRatio: 9 / 16,
  likesCount: 0,
  commentsCount: 0,
  repostsCount: 0,
  viewsCount: 0,
  pinned: false,
  createdAt: DateTime(2026, 10, 13),
  audience: audience,
);

Widget _app(Widget child) => MaterialApp(theme: AppTheme.dark, home: child);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('version compare', () {
    expect(compareVersions('0.4.1', '0.4.0'), 1);
    expect(compareVersions('v0.4.0', '0.4.0'), 0);
    expect(compareVersions('0.3.9', '0.4.0'), -1);
    expect(compareVersions('1.0.0+5', '0.9.9'), 1);
    expect(compareVersions('0.10.0', '0.9.0'), 1);
  });

  test('github release parsing picks the apk', () {
    final r = ReleaseInfo.fromJson({
      'tag_name': 'v0.4.0',
      'html_url': 'https://github.com/x/y/releases/tag/v0.4.0',
      'body': 'notes',
      'published_at': '2026-10-13T10:00:00Z',
      'assets': [
        {'name': 'notes.txt', 'browser_download_url': 'https://t'},
        {
          'name': 'InstantGram-build-9.apk',
          'browser_download_url': 'https://a',
        },
      ],
    })!;
    expect(r.version, '0.4.0');
    expect(r.downloadUrl, 'https://a');
    expect(ReleaseInfo.fromJson({'message': 'Not Found'}), isNull);
  });

  test('mailto keeps spaces and new lines', () {
    final u = mailtoUri('a@b.com', subject: 'Hi there', body: 'L1\nL2 & more');
    expect(
      u.toString(),
      'mailto:a@b.com?subject=Hi%20there&body=L1%0AL2%20%26%20more',
    );
  });

  test('report email goes to the support address', () {
    expect(ReportRepository.to, 'techlabs.hyper@gmail.com');
    final m = ReportRepository.postEmail(
      post: _post(),
      reason: 'Spam',
      message: 'This clip is spam.',
      reporterUsername: 'me',
      reporterUid: 'u1',
    );
    expect(m.subject, contains('Spam'));
    expect(m.body, contains('p1'));
    expect(m.body, contains('@me'));
  });

  test('40 languages with unique codes', () {
    expect(kLanguages.length, 40);
    expect(kLanguages.map((l) => l.code).toSet().length, 40);
    expect(languageByCode('hi')?.name, 'Hindi');
  });

  test('audience and private accounts', () {
    final f = ContentFilter.instance;
    f.debugSet(me: 'me', following: {'friend'}, private: {'priv'});
    expect(f.canSee(_post(author: 'x')), isTrue);
    expect(f.canSee(_post(author: 'x', audience: Audience.followers)), isFalse);
    expect(
      f.canSee(_post(author: 'friend', audience: Audience.followers)),
      isTrue,
    );
    expect(f.canSee(_post(author: 'x', audience: Audience.onlyMe)), isFalse);
    expect(f.canSee(_post(author: 'me', audience: Audience.onlyMe)), isTrue);
    expect(f.canSee(_post(author: 'priv')), isFalse);
    f.debugSet(me: 'me', blocked: {'x'});
    expect(f.canSee(_post(author: 'x')), isFalse);
  });

  test('minutes format', () {
    expect(formatMinutes(0), '0m');
    expect(formatMinutes(12 * 60 + 30), '12m');
    expect(formatMinutes(65 * 60), '1h 05m');
  });

  testWidgets('settings has every section and search works', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    const me = UserProfile(
      uid: 'me',
      name: 'Riya',
      username: 'riya',
      email: 'r@x.com',
    );
    await tester.pumpWidget(_app(const SettingsScreen(profile: me)));
    await tester.pump();
    for (final t in [
      'Account',
      'History',
      'Manage time',
      'Account privacy',
      'Blocked',
      'Accessibility',
      'Language',
      'App update',
      'About',
      'Privacy policy',
      'Terms of use',
      'Log out',
      'Delete account',
    ]) {
      await tester.scrollUntilVisible(
        find.text(t),
        80,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(t), findsOneWidget, reason: t);
    }
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('settings-search')),
      'block',
    );
    await tester.pump();
    expect(find.text('Blocked'), findsOneWidget);
    expect(find.text('History'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('settings-search')),
      'zzzz',
    );
    await tester.pump();
    expect(find.text('No settings found'), findsOneWidget);
  });

  testWidgets('manage time shows today and sets a reminder', (tester) async {
    final s = AppSettings.instance;
    final today = DateTime(2026, 10, 13, 12);
    s.usage.value = {AppSettings.dayKey(today): 25 * 60};
    await tester.pumpWidget(_app(TimeScreen(now: today)));
    await tester.pump();
    expect(find.text('25m'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('limit-30')));
    await tester.pump();
    expect(s.dailyLimitMinutes.value, 30);
    expect(s.shouldRemind(now: today), isFalse);
    await s.addUsage(6 * 60, now: today);
    expect(s.shouldRemind(now: today), isTrue);
    await s.markReminded(now: today);
    expect(s.shouldRemind(now: today), isFalse);
    await s.setDailyLimit(0);
  });
}
