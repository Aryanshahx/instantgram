import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/errors.dart';
import 'package:instantgram/models/app_user.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/screens/settings/account_screens.dart';
import 'package:instantgram/services/app_prefs.dart';
import 'package:instantgram/services/image_check.dart';
import 'package:instantgram/services/safety_service.dart';
import 'package:instantgram/widgets/sensitive_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

Post _post({
  String id = 'p1',
  String author = 'other',
  bool sensitive = false,
  int reports = 0,
  int weight = 0,
}) => Post(
  id: id,
  authorId: author,
  authorUsername: 'someone',
  authorPhotoUrl: '',
  type: 'image',
  caption: '',
  createdAt: DateTime(2026, 10, 10),
  sensitive: sensitive,
  reportCount: reports,
  reportWeight: weight,
);

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppPrefs.instance.init();
    SafetyService.instance.me = 'me';
    SafetyService.instance.autoHide = 0;
    revealedSensitive.clear();
    debugImageScorer = null;
    debugFrameGrab = null;
    tmp = Directory.systemTemp.createTempSync('v1320');
  });

  tearDown(() {
    debugImageScorer = null;
    debugFrameGrab = null;
    tmp.deleteSync(recursive: true);
  });

  File file(String name, List<int> bytes) =>
      File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  group('photo check', () {
    test('scores: what is blurred, reviewed or refused', () {
      const safe = ImageScores(neutral: 0.9, drawings: 0.1);
      expect(safe.sensitive, isFalse);
      // swimwear: the model says "sexy", nothing is blurred
      const sexy = ImageScores(neutral: 0.0, porn: 0.35, sexy: 0.65);
      expect(sexy.sensitive, isFalse);
      const some = ImageScores(neutral: 0.2, porn: 0.7, sexy: 0.1);
      expect(some.sensitive, isTrue);
      expect(some.review || some.badAvatar, isFalse);
      const porn = ImageScores(neutral: 0.05, porn: 0.9, sexy: 0.05);
      expect(porn.sensitive && porn.review && porn.badAvatar, isTrue);
      expect(
        ImageScores.fromList([0, 0.3, 0.2, 0.4, 0.1]).explicit,
        closeTo(0.7, 1e-9),
      );
    });

    test('the worst picture decides; what is saved on the post', () {
      final v = ImageVerdict.of(const [
        ImageScores(neutral: 1),
        ImageScores(neutral: 0.08, porn: 0.92),
      ]);
      expect(v.toFields(), {'imgCheck': 'ok', 'sensitive': true, 'nsfw': 0.92});
      expect(ImageVerdict.of(const [ImageScores(neutral: 1)]).toFields(), {
        'imgCheck': 'ok',
      });
      expect(ImageVerdict.skipped.toFields(), {'imgCheck': 'skipped'});
    });

    test('videos: three frames are looked at', () {
      expect(checkFrames(0), [0]);
      expect(checkFrames(30000), [500, 10000, 20000]);
      expect(checkFrames(600), [300, 200, 400]);
    });

    test(
      'check() runs every photo and video frame through the model',
      () async {
        final seen = <int>[];
        debugImageScorer = (b) async {
          seen.add(b.first);
          return b.first == 9
              ? const ImageScores(neutral: 0.1, porn: 0.85, sexy: 0.05)
              : const ImageScores(neutral: 1);
        };
        final frames = <int>[];
        debugFrameGrab = (path, ms) async {
          frames.add(ms);
          return Uint8List.fromList([ms == 10000 ? 9 : 2]);
        };
        final v = await ImageCheck.instance.check([
          CheckItem(file('a.jpg', [1])),
          CheckItem(file('b.mp4', [0]), video: true, durationMs: 30000),
        ]);
        expect(frames, [500, 10000, 20000]);
        expect(seen, [1, 2, 9, 2]);
        expect(v.checked && v.sensitive && v.review, isTrue);
      },
    );

    test(
      'without the model (tests, no internet) the upload goes on unchecked',
      () async {
        final v = await ImageCheck.instance.check([
          CheckItem(file('a.jpg', [1])),
        ], wait: const Duration(milliseconds: 50));
        expect(v.checked, isFalse);
        expect(v.toFields()['imgCheck'], 'skipped');
      },
    );

    test('profile photos with nudity are refused', () async {
      debugImageScorer = (_) async =>
          const ImageScores(neutral: 0.15, hentai: 0.8, sexy: 0.05);
      await expectLater(
        ImageCheck.instance.checkAvatar(file('me.jpg', [1])),
        throwsA(
          isA<ModerationException>().having(
            (e) => e.message,
            'message',
            contains('profile photo'),
          ),
        ),
      );
      debugImageScorer = (_) async => const ImageScores(neutral: 1);
      await ImageCheck.instance.checkAvatar(file('ok.jpg', [1]));
    });

    test('the model file in the repository is the expected one', () {
      final f = File('models/nsfw_mobilenet_v2_q.tflite');
      expect(f.lengthSync(), kNsfwModelBytes);
      expect(
        kNsfwModelUrl,
        endsWith('/main/models/nsfw_mobilenet_v2_q.tflite'),
      );
      expect(File('models/README.md').readAsStringSync(), contains('MIT'));
    });
  });

  group('blur', () {
    Widget gate(Post p, {bool compact = false}) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 300,
          height: 300,
          child: SensitiveGate(
            id: p.id,
            authorId: p.authorId,
            sensitive: p.sensitive,
            compact: compact,
            builder: (context, shown) =>
                Text(shown ? 'PLAYING' : 'PAUSED', key: const ValueKey('m')),
          ),
        ),
      ),
    );

    testWidgets('flagged posts are blurred and paused until Tap to view', (
      t,
    ) async {
      await t.pumpWidget(gate(_post(sensitive: true)));
      expect(find.text('Sensitive content'), findsOneWidget);
      expect(find.text('PAUSED'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('sensitive_p1')));
      await _settle(t);
      expect(find.text('Sensitive content'), findsNothing);
      expect(find.text('PLAYING'), findsOneWidget);
      expect(revealedSensitive, contains('p1'));
    });

    testWidgets('grid tiles only get an icon; normal posts nothing', (t) async {
      await t.pumpWidget(gate(_post(id: 'p2', sensitive: true), compact: true));
      expect(find.byIcon(Icons.visibility_off_rounded), findsOneWidget);
      expect(find.text('Tap to view'), findsNothing);
      await t.pumpWidget(gate(_post(id: 'p3')));
      expect(find.text('PLAYING'), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off_rounded), findsNothing);
    });

    testWidgets('my own posts and the setting show it unblurred', (t) async {
      expect(isBlurred('x', 'me', true), isFalse);
      expect(isBlurred('x', 'other', true), isTrue);
      await t.pumpWidget(const MaterialApp(home: SensitiveContentScreen()));
      expect(find.text('Blur sensitive content'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('sensitiveSwitch')));
      await _settle(t);
      expect(AppPrefs.instance.showSensitive, isTrue);
      expect(isBlurred('x', 'other', true), isFalse);
    });
  });

  group('trust and weighted reports', () {
    test('report weight follows trust (the rules use the same steps)', () {
      expect(reportPoints(10), 1);
      expect(reportPoints(kDefaultTrust), 2);
      expect(reportPoints(74), 2);
      expect(reportPoints(90), 3);
    });

    test('auto-hide counts 2 weight points as one report', () {
      final s = SafetyService.instance..autoHide = 3;
      expect(s.canSee(_post(reports: 3, weight: 5)), isTrue); // 2.5
      expect(s.canSee(_post(reports: 2, weight: 6)), isFalse); // two trusted
      expect(s.canSee(_post(reports: 3)), isFalse); // older reports, no weight
      expect(_post(weight: 3).effectiveReports, 1.5);
    });

    test('rules: weights checked, trust only set by the panel', () {
      final r = File('firebase/firestore.rules').readAsStringSync();
      expect(r, contains('function reportPointsOk(points)'));
      expect(r, contains("'trust', 'strikes', 'flags'"));
      expect(r, contains("'reportWeight', 'sensitive', 'nsfw', 'imgCheck'"));
      final a = File('signer/lib/admin.js').readAsStringSync();
      expect(a, contains('export function trustOf('));
      expect(a, contains('trust,\n};'));
    });
  });
}
