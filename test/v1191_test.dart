import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:instantgram/core/clip_focus.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/app_notification.dart';
import 'package:instantgram/screens/activity/activity_screen.dart';
import 'package:instantgram/screens/post/comments_screen.dart';
import 'package:instantgram/services/notification_service.dart';

AppNotification _note(
  String id, {
  String type = 'like',
  String name = 'riya',
  String text = '',
  String thumb = '',
  String postId = 'p1',
  bool read = false,
}) =>
    AppNotification(
      id: id,
      type: type,
      actorId: 'u_$name',
      actorName: name,
      postId: postId,
      thumb: thumb,
      text: text,
      createdAt: DateTime(2026, 10, 7, 9),
      read: read,
    );

/// The words of one row (rows are RichText, so there is no Text widget to find).
String _rowText(WidgetTester tester, String id) => tester
    .widgetList<RichText>(
      find.descendant(
        of: find.byKey(ValueKey('activity_$id')),
        matching: find.byType(RichText),
      ),
    )
    .map((w) => w.text.toPlainText())
    .join(' ');

void main() {
  setUp(() {
    ClipFocus.instance.reset();
    NotificationService.instance.testUid = 'me';
    NotificationService.instance.watchBackend = null;
    NotificationService.instance.sendBackend = null;
    NotificationService.instance.readBackend = () async {};
  });
  tearDown(() {
    ClipFocus.instance.reset();
    NotificationService.instance.testUid = null;
    NotificationService.instance.watchBackend = null;
    NotificationService.instance.sendBackend = null;
    NotificationService.instance.readBackend = null;
  });

  group('one clip plays at a time', () {
    test('the first clips screen plays, and a second one opened over it takes over',
        () {
      // the Clips tab has no token: it plays while nothing is open
      expect(ClipFocus.instance.canPlay(null), isTrue);

      final first = ClipFocus.instance.push();
      expect(ClipFocus.instance.canPlay(first), isTrue);
      // a clip in Discover goes quiet while a clips screen is open
      expect(ClipFocus.instance.canPlay(null), isFalse);

      // a clip opened from a comment on top of it
      final second = ClipFocus.instance.push();
      expect(ClipFocus.instance.canPlay(second), isTrue);
      expect(ClipFocus.instance.canPlay(first), isFalse);

      // closing the reply gives the sound back to the clip underneath
      ClipFocus.instance.pop(second);
      expect(ClipFocus.instance.canPlay(first), isTrue);
      expect(ClipFocus.instance.canPlay(second), isFalse);

      ClipFocus.instance.pop(first);
      expect(ClipFocus.instance.canPlay(null), isTrue);
    });

    test('screens that are closed twice, or never opened, do not take the sound',
        () {
      final token = Object();
      ClipFocus.instance.pop(token);
      expect(ClipFocus.instance.canPlay(null), isTrue);
      expect(ClipFocus.instance.anyOpen, isFalse);

      final a = ClipFocus.instance.push();
      ClipFocus.instance.pop(a);
      ClipFocus.instance.pop(a);
      expect(ClipFocus.instance.canPlay(null), isTrue);
    });

    test('the stack is watched, so screens rebuild when the front changes', () {
      var seen = 0;
      ClipFocus.instance.version.addListener(() => seen++);
      final a = ClipFocus.instance.push();
      final b = ClipFocus.instance.push();
      ClipFocus.instance.pop(b);
      ClipFocus.instance.pop(a);
      expect(seen, 4);
    });
  });

  group('the comments over a clip', () {
    testWidgets('the sheet keeps a strip of the clip visible on a phone',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (c) {
              final h = MediaQuery.of(c).size.height;
              final sheet = commentsSheetHeight(c);
              return Scaffold(
                body: Center(
                  child: Text(
                    '${sheet.round()} of ${h.round()}',
                    key: const ValueKey('size'),
                  ),
                ),
              );
            },
          ),
        ),
      );
      final t = tester.widget<Text>(find.byKey(const ValueKey('size'))).data!;
      final parts = t.split(' ');
      final sheet = double.parse(parts[0]);
      final h = double.parse(parts[2]);
      // about two thirds of the screen, and never the whole screen
      expect(sheet, greaterThan(h * 0.5));
      expect(sheet, lessThan(h * 0.85));
      // the clip keeps at least a third of the screen above the comments
      expect((h - sheet) / h, greaterThanOrEqualTo(0.28));
    });
  });

  group('activity', () {
    test('a like, a comment and a follow are written, never to the person who did it',
        () async {
      final written = <Map<String, dynamic>>[];
      NotificationService.instance.sendBackend = (item) async {
        written.add(item);
      };

      await NotificationService.instance.notify(
        toUid: 'other',
        type: 'like',
        postId: 'p9',
        thumb: 'm:thumb',
      );
      await NotificationService.instance.notify(toUid: 'me', type: 'like');
      await NotificationService.instance.notify(toUid: '', type: 'like');

      expect(written.length, 1);
      expect(written.single['actorId'], 'me');
      expect(written.single['type'], 'like');
      expect(written.single['postId'], 'p9');
      expect(written.single['thumb'], 'm:thumb');
      expect(written.single['read'], isFalse);
    });

    test('the red dot counts what is new', () async {
      NotificationService.instance.watchBackend = () => Stream.value([
            _note('a'),
            _note('b', type: 'comment', text: 'nice one', read: true),
            _note('c', type: 'follow', read: true),
          ]);
      await expectLater(NotificationService.instance.watchUnread(), emits(1));
    });

    testWidgets('the list shows who did what, and the post next to it',
        (tester) async {
      NotificationService.instance.watchBackend = () => Stream.value([
            _note('a'),
            _note('b', type: 'comment', text: 'nice one'),
            _note('c', type: 'follow', postId: ''),
          ]);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark, home: const ActivityScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const ValueKey('activity_a')), findsOneWidget);
      expect(find.byKey(const ValueKey('activity_b')), findsOneWidget);
      expect(find.byKey(const ValueKey('activity_c')), findsOneWidget);
      expect(_rowText(tester, 'a'), contains('riya liked your post'));
      expect(_rowText(tester, 'b'), contains('riya commented'));
      expect(_rowText(tester, 'b'), contains('nice one'));
      expect(_rowText(tester, 'c'), contains('riya started following you'));
    });

    testWidgets('nothing yet, while nobody has done anything', (tester) async {
      NotificationService.instance.watchBackend = () => Stream.value([]);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark, home: const ActivityScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Nothing yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('activity_a')), findsNothing);
    });

    testWidgets('opening the screen marks everything as seen', (tester) async {
      var read = 0;
      NotificationService.instance.readBackend = () async => read++;
      NotificationService.instance.watchBackend = () => Stream.value([
            _note('a'),
          ]);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark, home: const ActivityScreen()),
      );
      await tester.pump();
      expect(read, 1);
    });
  });
}
