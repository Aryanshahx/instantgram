import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/errors.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/music.dart';
import 'package:instantgram/screens/auth/login_screen.dart';
import 'package:instantgram/services/auth_service.dart';
import 'package:instantgram/widgets/brand_logo.dart';
import 'package:instantgram/widgets/music_widgets.dart';
import 'package:instantgram/widgets/reel_progress.dart';

class _FakeSource implements ReelProgressSource {
  double f = 0.25;
  final calls = <String>[];
  @override
  double get fraction => f;
  @override
  double get buffered => 0.6;
  @override
  Duration get position => Duration(seconds: (total.inSeconds * f).round());
  @override
  Duration get total => const Duration(seconds: 20);
  @override
  void scrubStart() => calls.add('start');
  @override
  void scrub(double x) {
    f = x;
    calls.add('scrub ${x.toStringAsFixed(2)}');
  }

  @override
  void scrubEnd() => calls.add('end');
  @override
  void dispose() {}
}

void main() {
  group('username login helpers', () {
    test('usernames are normalised', () {
      expect(AuthService.normalizeUsername('  @Aryan.X '), 'aryan.x');
      expect(AuthService.normalizeUsername('abc'), 'abc');
    });

    test('an email is hidden in the confirmation', () {
      expect(AuthService.maskEmail('aryan@gmail.com'), 'a***@gmail.com');
      expect(AuthService.maskEmail('nothing'), 'nothing');
    });

    test('lookup errors are shown as they are', () {
      expect(
        friendlyError(
          const LoginLookupException('No account has that username.'),
        ),
        'No account has that username.',
      );
    });
  });

  group('forgot password', () {
    testWidgets('opens from the login screen, prefilled with what was typed', (
      t,
    ) async {
      await t.pumpWidget(
        MaterialApp(theme: AppTheme.dark, home: const LoginScreen()),
      );
      await t.enterText(find.byType(TextFormField).first, 'aryan');
      await t.tap(find.text('Forgot password?'));
      await t.pumpAndSettle();
      expect(find.text('Reset password'), findsOneWidget);
      expect(find.text('Send link'), findsOneWidget);
      final field = t.widget<TextField>(find.byType(TextField).last);
      expect(field.controller!.text, 'aryan');
    });

    testWidgets('an empty box says what to do and sends nothing', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: ForgotPasswordDialog()),
        ),
      );
      await t.tap(find.text('Send link'));
      await t.pump();
      expect(find.text('Enter your email or username.'), findsOneWidget);
    });
  });

  group('brand', () {
    testWidgets('wordmark is plain text', (t) async {
      await t.pumpWidget(
        const MaterialApp(home: Scaffold(body: BrandWordmark(size: 30))),
      );
      expect(find.text('InstantGram'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });
  });

  group('audio name', () {
    testWidgets('shows the track name, nothing for no track', (t) async {
      final track = kMusicLibrary.first;
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Column(
              children: [
                MusicLabel(musicId: track.id, onDark: false),
                const MusicLabel(musicId: 'nope'),
              ],
            ),
          ),
        ),
      );
      expect(find.text(track.title), findsOneWidget);
      expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
    });
  });

  group('smooth progress', () {
    final t0 = DateTime(2026, 1, 1);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

    test('moves between the player\'s coarse reports', () {
      final c = SmoothClock();
      const total = Duration(seconds: 10);
      c.sample(Duration.zero, playing: true, speed: 1, now: at(0));
      expect(c.shown(at(250), total), const Duration(milliseconds: 250));
      expect(c.shown(at(400), total), const Duration(milliseconds: 400));
      // next report arrives (a little behind our estimate): no jump back
      c.sample(
        const Duration(milliseconds: 480),
        playing: true,
        speed: 1,
        now: at(500),
      );
      expect(
        c.shown(at(500), total) >= const Duration(milliseconds: 480),
        isTrue,
      );
      expect(
        c.shown(at(700), total) > const Duration(milliseconds: 600),
        isTrue,
      );
    });

    test('stands still while paused and follows the 2x speed', () {
      final c = SmoothClock();
      const total = Duration(seconds: 10);
      c.sample(
        const Duration(seconds: 2),
        playing: false,
        speed: 1,
        now: at(0),
      );
      expect(c.shown(at(900), total), const Duration(seconds: 2));
      c.sample(
        const Duration(seconds: 2),
        playing: true,
        speed: 2,
        now: at(1000),
      );
      expect(c.shown(at(1500), total), const Duration(seconds: 3));
    });

    test('never passes the end, and follows a loop or a search back', () {
      final c = SmoothClock();
      const total = Duration(seconds: 4);
      c.sample(const Duration(seconds: 3), playing: true, speed: 1, now: at(0));
      expect(c.shown(at(5000), total), total);
      c.sample(Duration.zero, playing: true, speed: 1, now: at(5100));
      expect(c.shown(at(5150), total) < const Duration(seconds: 1), isTrue);
    });

    test('a report with the same position does not stall the line', () {
      final c = SmoothClock();
      const total = Duration(seconds: 10);
      c.sample(Duration.zero, playing: true, speed: 1, now: at(0));
      c.sample(Duration.zero, playing: true, speed: 1, now: at(300));
      expect(c.shown(at(400), total), const Duration(milliseconds: 400));
    });
  });

  group('progress bar', () {
    testWidgets('draws nothing until a clip reports, then follows touch', (
      t,
    ) async {
      final host = ReelProgressHost();
      addTearDown(host.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ReelProgressBar(host: host),
            ),
          ),
        ),
      );
      expect(find.byType(CustomPaint), findsWidgets);
      final src = _FakeSource();
      host.offer(src);
      await t.pump(const Duration(milliseconds: 50));

      // tap in the middle searches there
      final size = t.getSize(find.byType(ReelProgressBar));
      final topLeft = t.getTopLeft(find.byType(ReelProgressBar));
      await t.tapAt(topLeft + Offset(size.width * 0.5, size.height / 2));
      await t.pump(const Duration(milliseconds: 50));
      expect(src.calls, ['start', 'scrub 0.50', 'end']);

      // dragging follows the finger and shows the time
      src.calls.clear();
      final g = await t.startGesture(
        topLeft + Offset(size.width * 0.1, size.height / 2),
      );
      await g.moveBy(Offset(size.width * 0.4, 0));
      await t.pump(const Duration(milliseconds: 50));
      expect(find.textContaining(' / 0:20'), findsOneWidget);
      await g.up();
      await t.pump(const Duration(milliseconds: 50));
      expect(src.calls.first, 'start');
      expect(src.calls.last, 'end');
      expect(src.f, closeTo(0.5, 0.15));

      // taking the clip away clears the line
      host.withdraw(src);
      await t.pump(const Duration(milliseconds: 50));
      expect(t.takeException(), isNull);
    });

    testWidgets('a vertical swipe on the bar does not search', (t) async {
      final host = ReelProgressHost();
      addTearDown(host.dispose);
      final src = _FakeSource();
      host.offer(src);
      // the clips PageView (vertical) competes for the same touches
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageView(
              scrollDirection: Axis.vertical,
              children: [
                Align(
                  alignment: Alignment.bottomCenter,
                  child: ReelProgressBar(host: host),
                ),
                const SizedBox(),
              ],
            ),
          ),
        ),
      );
      await t.drag(find.byType(ReelProgressBar), const Offset(0, -80));
      await t.pump();
      expect(src.calls, isEmpty);
    });
  });
}
