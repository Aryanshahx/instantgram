import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/l10n.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/services/app_prefs.dart';
import 'package:instantgram/services/report_service.dart';
import 'package:instantgram/widgets/reel_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

Post _post({String type = 'image'}) => Post(
  id: 'p1',
  authorId: 'owner1',
  authorUsername: 'owner',
  authorPhotoUrl: '',
  type: type,
  caption: 'hello',
  createdAt: DateTime(2026, 1, 1),
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
    debugReportSink = null;
  });
  tearDown(() => debugReportSink = null);

  group('reports for the admin panel', () {
    test('a clip report names the clip and its owner', () {
      final d = reportData(
        _post(type: 'video'),
        by: 'me1',
        reason: 'Spam',
        text: 'sells things',
      );
      expect(d['kind'], 'clip');
      expect(d['postId'], 'p1');
      expect(d['ownerId'], 'owner1');
      expect(d['status'], 'open');
      expect(d.containsKey('commentId'), isFalse);
    });

    test('a comment report is about the comment author', () {
      final d = reportData(
        _post(),
        by: 'me1',
        reason: 'Hate or harassment',
        text: 'rude',
        commentId: 'c9',
        comment: 'you are bad',
        commentAuthorId: 'troll1',
        commentAuthorUsername: 'troll',
      );
      expect(d['kind'], 'comment');
      expect(d['commentId'], 'c9');
      expect(d['ownerId'], 'troll1');
      expect(d['ownerUsername'], 'troll');
    });

    testWidgets('sending the form saves the report', (t) async {
      final saved = <Map<String, Object?>>[];
      debugReportSink = (d) async => saved.add(d);
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
      await t.tap(find.text('Spam'));
      await t.enterText(find.byKey(const ValueKey('reportText')), 'bad post');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('reportSend')));
      await t.pumpAndSettle();
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(saved, hasLength(1));
      expect(saved.single['reason'], 'Spam');
      expect(saved.single['text'], 'bad post');
      expect(find.textContaining('Report sent'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
    });
  });

  group('rules and signer', () {
    test('only the panel reads reports; users cannot unban themselves', () {
      final rules = File('firebase/firestore.rules').readAsStringSync();
      expect(rules, contains('match /reports/{reportId}'));
      expect(rules, contains('allow read, update, delete: if false;'));
      expect(rules, contains("hasAny(['banned', 'bannedReason'])"));
      expect(rules, contains("!('banned' in request.resource.data)"));
    });

    test('the signer serves the panel at /admin', () {
      final v =
          jsonDecode(File('signer/vercel.json').readAsStringSync()) as Map;
      final rw = (v['rewrites'] as List).cast<Map>();
      expect(rw.any((r) => r['source'] == '/admin'), isTrue);
      final html = File('signer/lib/panel.html').readAsStringSync();
      expect(html, contains('/api/admin'));
      expect(File('signer/api/panel.js').existsSync(), isTrue);
    });
  });
}
