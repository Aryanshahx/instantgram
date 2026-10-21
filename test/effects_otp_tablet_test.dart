// v0.0.1: face effects helpers, smooth timeline, tablets, sign up email
// code, moment delete / close.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/services/api_client.dart';
import 'package:instantgram/core/services/content_filter.dart';
import 'package:instantgram/core/services/music_player.dart';
import 'package:instantgram/core/services/presence.dart';
import 'package:instantgram/core/services/vision_service.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/auth/data/auth_service.dart';
import 'package:instantgram/features/auth/presentation/email_code_screen.dart';
import 'package:instantgram/features/stories/presentation/story_viewer_screen.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/widgets/face_effects.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:instantgram/shared/widgets/smooth_clock.dart';
import 'package:instantgram/shared/widgets/tablet_frame.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _t0 = DateTime(2026, 10, 20, 9);

Story _story(String id, {String author = 'me'}) => Story(
  id: id,
  authorId: author,
  authorUsername: author,
  authorPhotoUrl: '',
  mediaUrl: 'https://x/$id.jpg',
  mediaKey: 'story/$author/$id',
  createdAt: _t0,
);

Future<void> _frames(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _finish(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 1));
}

/// Which moment is on screen (its photo).
String? _shownStory(WidgetTester t) {
  final w = t.widgetList<NetImage>(find.byType(NetImage));
  for (final n in w) {
    final m = RegExp(r'https://x/(\w+)\.jpg').firstMatch(n.url);
    if (m != null) return m.group(1);
  }
  return null;
}

void main() {
  setUpAll(() {
    NetImage.disableCache = true;
    MusicPlayer.disabled = true;
    Presence.instance.show.value = false;
    ContentFilter.instance.debugSet(me: 'me');
  });

  // ------------------------------------------------------- smooth timeline
  group('SmoothClock (no shaking timeline)', () {
    test('moves every frame between the slow player updates', () {
      final c = SmoothClock();
      expect(c.position(reported: 1000, playing: true, nowMs: 0), 1000);
      // the player says 1000 for 500 ms, the clock keeps going
      expect(c.position(reported: 1000, playing: true, nowMs: 16), 1016);
      expect(c.position(reported: 1000, playing: true, nowMs: 250), 1250);
      expect(c.position(reported: 1000, playing: true, nowMs: 480), 1480);
    });

    test('a slightly late player update never moves it back', () {
      final c = SmoothClock();
      c.position(reported: 0, playing: true, nowMs: 0);
      final a = c.position(reported: 0, playing: true, nowMs: 500);
      // player was a bit behind (450 instead of 500)
      final b = c.position(reported: 450, playing: true, nowMs: 501);
      expect(b, greaterThanOrEqualTo(a));
      var last = b;
      for (var t = 516; t < 1500; t += 16) {
        final p = c.position(reported: 450, playing: true, nowMs: t);
        expect(p, greaterThanOrEqualTo(last));
        last = p;
      }
    });

    test('a seek / loop jumps at once; paused = the player position', () {
      final c = SmoothClock();
      c.position(reported: 0, playing: true, nowMs: 0);
      c.position(reported: 0, playing: true, nowMs: 300);
      expect(c.position(reported: 9000, playing: true, nowMs: 316), 9000);
      expect(c.position(reported: 0, playing: true, nowMs: 332), 0);
      expect(c.position(reported: 4321, playing: false, nowMs: 900), 4321);
      expect(c.position(reported: 4321, playing: false, nowMs: 2000), 4321);
      c.reset();
      expect(c.position(reported: 10, playing: true, nowMs: 3000), 10);
    });

    test('speed 2x moves twice as fast', () {
      final c = SmoothClock();
      c.position(reported: 0, playing: true, nowMs: 0, speed: 2);
      expect(c.position(reported: 0, playing: true, nowMs: 100, speed: 2), 200);
    });
  });

  // ------------------------------------------------------- camera frames
  group('camera frames for ML Kit', () {
    test('shrinkNv21 keeps every n-th pixel, Y and UV', () {
      const w = 8, h = 4;
      final src = Uint8List(w * h * 3 ~/ 2);
      for (var i = 0; i < w * h; i++) {
        src[i] = i;
      }
      for (var i = 0; i < w * h ~/ 2; i++) {
        src[w * h + i] = 200 + i % 50;
      }
      final f = shrinkNv21(src, w, h, target: 2)!;
      expect(f.width, 4);
      expect(f.height, 2);
      expect(f.bytes.length, 4 * 2 * 3 ~/ 2);
      // Y: rows 0 and 2, columns 0,2,4,6
      expect(f.bytes.sublist(0, 8), [0, 2, 4, 6, 16, 18, 20, 22]);
      // UV row 0: pairs at x = 0, 4 (V,U kept together)
      expect(f.bytes.sublist(8), [200, 201, 204, 205]);
    });

    test('rows longer than the width (stride) are read right', () {
      const w = 4, h = 2, stride = 6;
      final src = Uint8List(stride * h + stride * (h ~/ 2));
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          src[y * stride + x] = 10 * y + x;
        }
      }
      final f = shrinkNv21(src, w, h, stride: stride, target: 2)!;
      expect(f.width, 4);
      expect(f.height, 2);
      expect(f.bytes.sublist(0, 8), [0, 1, 2, 3, 10, 11, 12, 13]);
    });

    test('bad frames are skipped; 1080p becomes small', () {
      expect(shrinkNv21(Uint8List(10), 8, 4), isNull);
      expect(shrinkNv21(Uint8List(0), 1, 1), isNull);
      final big = shrinkNv21(Uint8List(1920 * 1080 * 3 ~/ 2), 1920, 1080)!;
      expect(big.height, lessThanOrEqualTo(270));
      expect(big.width.isEven && big.height.isEven, isTrue);
    });

    test('frame rotation for back / front cameras', () {
      expect(frameRotation(90, front: false), 90);
      expect(frameRotation(270, front: true), 270);
      expect(frameRotation(90, front: false, device: 90), 0);
      expect(frameRotation(270, front: true, device: 90), 0);
    });
  });

  // ------------------------------------------------------- face track
  group('face track (effects on filmed videos)', () {
    const a = FaceBox(
      lx: 0.4,
      ly: 0.4,
      rx: 0.6,
      ry: 0.4,
      l: 0.3,
      t: 0.3,
      r: 0.7,
      b: 0.7,
    );
    const b = FaceBox(
      lx: 0.5,
      ly: 0.5,
      rx: 0.7,
      ry: 0.5,
      l: 0.4,
      t: 0.4,
      r: 0.8,
      b: 0.8,
    );

    test('encode -> parse gives the same samples', () {
      const tr = FaceTrack([0, 200, 400], [a, null, b]);
      final s = tr.encode();
      expect(s, startsWith('v1;0,0.400,'));
      final back = FaceTrack.parse(s)!;
      expect(back.times, [0, 200, 400]);
      expect(back.faces[1], isNull);
      expect(back.faces[2]!.r, closeTo(0.8, 1e-9));
      expect(back.hasFace, isTrue);
    });

    test('at(): smooth between samples, no slide over long gaps', () {
      const tr = FaceTrack([0, 1000, 4000], [a, b, a]);
      final mid = tr.at(500)!;
      expect(mid.l, closeTo(0.35, 1e-9));
      expect(tr.at(-5)!.l, a.l);
      expect(tr.at(99999)!.l, a.l);
      // 3 s between samples: jump at the middle
      expect(tr.at(2000)!.l, b.l);
      expect(tr.at(3000)!.l, a.l);
      const gap = FaceTrack([0, 200], [a, null]);
      expect(gap.at(50), isNotNull);
      expect(gap.at(150), isNull);
    });

    test('bad text is ignored', () {
      expect(FaceTrack.parse(''), isNull);
      expect(FaceTrack.parse('v2;0'), isNull);
      final t = FaceTrack.parse('v1;0,1,2;x;100,0.1,0.1,0.2,0.1,0.9,0.9,0.1,0.1')!;
      // wrong count = no face, a box with r < l = no face
      expect(t.times, [0, 100]);
      expect(t.faces, [null, null]);
    });

    test('FaceFx saved with the post', () {
      const fx = FaceFx(effect: 'sunglasses', track: 'v1;0;100');
      final back = FaceFx.fromMap(fx.toMap())!;
      expect(back.effect, 'sunglasses');
      expect(back.track, 'v1;0;100');
      expect(FaceFx.fromMap({'fx': '', 't': 'v1'}), isNull);
      expect(FaceFx.fromMap({'fx': 'dog', 't': 'nope'}), isNull);
      expect(FaceFx.fromMap('x'), isNull);
      expect(kFaceEffects.length, 14);
      expect(isFaceEffect('crown'), isTrue);
      expect(isFaceEffect('nope'), isFalse);
    });
  });

  // ------------------------------------------------------- tablets
  group('tablets', () {
    test('column width for each screen', () {
      expect(tabletFrameWidth(const Size(411, 891)), isNull); // phone
      expect(tabletFrameWidth(const Size(800, 1280)), isNull); // tablet up
      expect(tabletFrameWidth(const Size(1280, 800)), 640); // tablet side
      expect(tabletFrameWidth(const Size(1024, 1366)), 820); // big tablet
      expect(tabletFrameWidth(const Size(2560, 1600)), 720);
      expect(tabletFrameWidth(const Size(891, 411)), 420); // phone side
    });

    testWidgets('the app sits in a centered column, sheets too', (t) async {
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      Size? seen;
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          builder: (context, child) => TabletFrame(child: child!),
          home: Builder(
            builder: (context) {
              seen = MediaQuery.of(context).size;
              return Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      builder: (_) => const SizedBox(
                        key: ValueKey('sheet'),
                        height: 100,
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              );
            },
          ),
        ),
      );
      expect(find.byKey(const ValueKey('tablet-frame')), findsOneWidget);
      expect(seen, const Size(640, 800));
      expect(t.getSize(find.byType(Scaffold)).width, 640);
      expect(t.getTopLeft(find.byType(Scaffold)).dx, 320);
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      final r = t.getRect(find.byKey(const ValueKey('sheet')));
      expect(r.left, greaterThanOrEqualTo(320));
      expect(r.right, lessThanOrEqualTo(960));
    });

    testWidgets('phone: no frame', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.625;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          builder: (context, child) => TabletFrame(child: child!),
          home: const Scaffold(),
        ),
      );
      expect(find.byKey(const ValueKey('tablet-frame')), findsNothing);
    });
  });

  // ------------------------------------------------------- email code
  group('sign up email code', () {
    late List<Map<String, dynamic>> sent;
    setUp(() {
      sent = [];
      AuthService.debugApi = (path, body) async {
        sent.add({'path': path, ...body});
        if (body['action'] == 'otpSend') return {'sent': true, 'resendIn': 60};
        if (body['action'] == 'otpVerify') {
          if (body['code'] == '123456') return {'otpToken': 'tok1'};
          throw const ApiException('Wrong code. 4 tries left.', statusCode: 400);
        }
        return {};
      };
    });
    tearDown(() => AuthService.debugApi = null);

    test('service: send + verify go to /api/u without login', () async {
      expect(await AuthService.instance.sendSignupCode(' a@b.co '), 60);
      expect(sent.last, {'path': '/api/u', 'action': 'otpSend', 'email': 'a@b.co'});
      expect(await AuthService.instance.verifySignupCode('a@b.co', '123456'), 'tok1');
      await expectLater(
        AuthService.instance.verifySignupCode('a@b.co', '000000'),
        throwsA(isA<AuthFailure>().having((e) => e.message, 'm', contains('Wrong code'))),
      );
    });

    testWidgets('wrong code -> message; right code -> account made', (t) async {
      final made = <String>[];
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: EmailCodeScreen(
            email: 'riya@mail.com',
            onVerified: (tok) async => made.add(tok),
          ),
        ),
      );
      await t.pump();
      expect(find.textContaining('riya@mail.com'), findsOneWidget);
      expect(find.text('Send again in 60s'), findsOneWidget);
      // verify without a code
      await t.tap(find.byKey(const ValueKey('otp-verify')));
      await t.pump();
      expect(find.text('Enter the 6 digit code.'), findsOneWidget);
      // letters are not typed, 6 digits verify by themselves
      await t.enterText(find.byKey(const ValueKey('otp-field')), '00a0000');
      await t.pump();
      await t.pump();
      expect(find.text('Wrong code. 4 tries left.'), findsOneWidget);
      expect(made, isEmpty);
      await t.enterText(find.byKey(const ValueKey('otp-field')), '123456');
      await t.pump();
      await t.pump();
      expect(made, ['tok1']);
      expect(find.byKey(const ValueKey('otp-error')), findsNothing);
      await _finish(t);
    });

    testWidgets('account step fails -> try again uses the same code', (t) async {
      var n = 0;
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: EmailCodeScreen(
            email: 'riya@mail.com',
            onVerified: (tok) async {
              n++;
              if (n == 1) throw const AuthFailure('That username is taken.');
            },
          ),
        ),
      );
      await t.enterText(find.byKey(const ValueKey('otp-field')), '123456');
      await t.pump();
      await t.pump();
      expect(find.text('That username is taken.'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('otp-verify')));
      await t.pump();
      await t.pump();
      expect(n, 2);
      // the code was checked only once
      expect(sent.where((s) => s['action'] == 'otpVerify').length, 1);
      await _finish(t);
    });

    testWidgets('send again after 60 s', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: EmailCodeScreen(
            email: 'riya@mail.com',
            onVerified: (_) async {},
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('otp-resend')));
      await t.pump();
      expect(sent, isEmpty);
      await t.pump(const Duration(seconds: 30));
      expect(find.text('Send again in 30s'), findsOneWidget);
      await t.pump(const Duration(seconds: 31));
      expect(find.text('Send again'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('otp-resend')));
      await t.pump();
      await t.pump();
      expect(sent.single['action'], 'otpSend');
      expect(find.text('New code sent'), findsOneWidget);
      expect(find.text('Send again in 60s'), findsOneWidget);
      await _finish(t);
    });
  });

  // ------------------------------------------------------- moments
  group('moment delete and close', () {
    late List<String> deleted;
    setUp(() {
      deleted = [];
      StoryViewerScreen.debugMe = 'me';
      StoryViewerScreen.debugViews = (id) => const Stream.empty();
      StoryViewerScreen.debugDelete = (st) async => deleted.add(st.id);
      StoryViewerScreen.debugRecordView = (st) async {};
      StoryViewerScreen.debugMyLike = (id) async => false;
      StoryViewerScreen.debugLike = (st, on) async {};
    });
    tearDown(() {
      StoryViewerScreen.debugMe = null;
      StoryViewerScreen.debugViews = null;
      StoryViewerScreen.debugDelete = null;
      StoryViewerScreen.debugRecordView = null;
      StoryViewerScreen.debugMyLike = null;
      StoryViewerScreen.debugLike = null;
    });

    Future<void> open(WidgetTester t, List<StoryGroup> groups) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.5;
      addTearDown(t.view.reset);
      SharedPreferences.setMockInitialValues({});
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(ctx).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        StoryViewerScreen(groups: groups, recordViews: true),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await _frames(t, 5);
    }

    Future<void> deleteNow(WidgetTester t) async {
      await t.tap(find.byKey(const ValueKey('story-delete')));
      await _frames(t, 3);
      await t.tap(find.text('Delete'));
      await _frames(t, 4);
    }

    testWidgets('delete -> next moment stays open; last one closes', (t) async {
      final groups = [
        StoryGroup('me', [_story('s1'), _story('s2')]),
      ];
      await open(t, groups);
      expect(_shownStory(t), 's1');
      await deleteNow(t);
      expect(deleted, ['s1']);
      expect(find.text('Moment deleted'), findsOneWidget);
      expect(find.byType(StoryViewerScreen), findsOneWidget);
      expect(_shownStory(t), 's2');
      // the list given to the viewer is not changed
      expect(groups.single.stories.length, 2);
      await deleteNow(t);
      expect(deleted, ['s1', 's2']);
      await t.pumpAndSettle();
      expect(find.byType(StoryViewerScreen), findsNothing);
      expect(find.text('open'), findsOneWidget);
      await _finish(t);
    });

    testWidgets('cancel keeps it; a failed delete says so', (t) async {
      await open(t, [
        StoryGroup('me', [_story('s1')]),
      ]);
      await t.tap(find.byKey(const ValueKey('story-delete')));
      await _frames(t, 3);
      await t.tap(find.text('Cancel'));
      await _frames(t, 3);
      expect(deleted, isEmpty);
      StoryViewerScreen.debugDelete = (st) async => throw StateError('offline');
      await deleteNow(t);
      expect(find.text("Couldn't delete. Check your internet."), findsOneWidget);
      expect(find.byType(StoryViewerScreen), findsOneWidget);
      await _finish(t);
    });

    testWidgets('X closes; no delete on other people\'s moments', (t) async {
      await open(t, [
        StoryGroup('riya', [_story('r1', author: 'riya')]),
      ]);
      expect(find.byKey(const ValueKey('story-delete')), findsNothing);
      await t.tap(find.byKey(const ValueKey('story-close')));
      await t.pumpAndSettle();
      expect(find.byType(StoryViewerScreen), findsNothing);
      await _finish(t);
    });
  });
}
