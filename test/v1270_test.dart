import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/app_notification.dart';
import 'package:instantgram/models/chat.dart';
import 'package:instantgram/models/story_view.dart';
import 'package:instantgram/screens/settings/app_icon_screen.dart';
import 'package:instantgram/services/custom_icon.dart';
import 'package:instantgram/services/story_views.dart';
import 'package:instantgram/widgets/edit_timeline.dart';
import 'package:instantgram/widgets/like_button.dart';
import 'package:instantgram/widgets/story_viewers_sheet.dart';

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

const _channel = MethodChannel('instantgram/app_icon');

/// A small picture (not square) made in the test.
Future<Uint8List> _picture(int w, int h) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFF3366FF),
  );
  final img = await rec.endRecording().toImage(w, h);
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  return d!.buffer.asUint8List();
}

Future<Size> _size(Uint8List png) async {
  final c = await ui.instantiateImageCodec(png);
  final f = await c.getNextFrame();
  return Size(f.image.width.toDouble(), f.image.height.toDouble());
}

void main() {
  group('moment likes', () {
    test('the view line carries the like and the super heart', () {
      final now = DateTime(2026, 10, 9, 12);
      final m = <String, dynamic>{'username': 'zoe', 'count': 2};
      expect(StoryView.fromMap('u1', m).liked, isFalse);
      final liked = StoryView.fromMap('u1', {...m, 'liked': true});
      expect(liked.liked, isTrue);
      expect(liked.superHeart, isFalse);
      final sup = StoryView.fromMap('u1', {...m, 'superHeart': true});
      expect(sup.liked, isTrue);
      expect(sup.superHeart, isTrue);
      expect(now.year, 2026);
    });

    testWidgets('the viewer list shows who liked', (t) async {
      final now = DateTime(2026, 10, 9, 12);
      StoryViews.instance.listBackend = (id) async => [
        StoryView(uid: 'u1', username: 'zoe', first: now, last: now),
        StoryView(
          uid: 'u2',
          username: 'zack',
          first: now,
          last: now,
          liked: true,
        ),
        StoryView(
          uid: 'u3',
          username: 'bob',
          first: now,
          last: now,
          liked: true,
          superHeart: true,
        ),
      ];
      StoryViews.instance.alertsBackend = () async => [];
      addTearDown(() {
        StoryViews.instance.listBackend = null;
        StoryViews.instance.alertsBackend = null;
        StoryViews.instance.forget();
      });
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StoryViewersSheet(storyId: 's1', now: now),
          ),
        ),
      );
      await _settle(t);
      expect(find.byKey(const ValueKey('viewerLike_u1')), findsNothing);
      final like = t.widget<Icon>(find.byKey(const ValueKey('viewerLike_u2')));
      expect(like.color, isNot(kSuperHeartColor));
      final sup = t.widget<Icon>(find.byKey(const ValueKey('viewerLike_u3')));
      expect(sup.color, kSuperHeartColor);
    });

    test('Notifications lines for moment likes', () {
      AppNotification n(String type) =>
          AppNotification(id: 'x', type: type, actorName: 'zoe');
      expect(n('story_like').verb, 'liked your moment');
      expect(n('story_super').verb, contains('super heart'));
      expect(n('story_like').isStoryView, isTrue);
    });

    testWidgets('holding a post heart sends no super heart', (t) async {
      final c = LikeController('p', 4);
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Center(child: HeartButton(controller: c)),
          ),
        ),
      );
      await _settle(t);
      await t.longPress(find.byType(HeartButton));
      await t.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('superBurst')), findsNothing);
      expect(c.superHeart, isFalse);
      await t.pump(const Duration(seconds: 2));
    });
  });

  group('seen in chats', () {
    final at = DateTime(2026, 10, 9, 12);
    ChatThread thread({String sender = 'me', DateTime? otherSeen}) =>
        ChatThread(
          id: 'me_you',
          members: const ['me', 'you'],
          lastText: 'hi',
          lastAt: at,
          lastSender: sender,
          seen: {'you': ?otherSeen},
        );

    test('Seen once they opened it after my message', () {
      expect(thread().seenByOther('me'), isFalse);
      expect(
        thread(
          otherSeen: at.subtract(const Duration(minutes: 1)),
        ).seenByOther('me'),
        isFalse,
      );
      expect(
        thread(otherSeen: at.add(const Duration(seconds: 3))).seenByOther('me'),
        isTrue,
      );
      // their message: never "Seen" for me
      expect(
        thread(
          sender: 'you',
          otherSeen: at.add(const Duration(seconds: 3)),
        ).seenByOther('me'),
        isFalse,
      );
    });
  });

  group('edit timeline', () {
    testWidgets('trim handles are always there; touching pauses', (t) async {
      await t.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final pos = ValueNotifier<double>(0);
      var touches = 0, grabbed = 0, released = 0;
      final ranges = <(double, double)>[];
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: EditTimeline(
                total: 20,
                start: 0,
                end: 20,
                position: pos,
                height: 240,
                onTouch: () => touches++,
                onRangeStart: () => grabbed++,
                onRangeEnd: () => released++,
                onRange: (s, e, _) => ranges.add((s, e)),
              ),
            ),
          ),
        ),
      );
      await _settle(t);
      expect(find.byKey(const ValueKey('trimStart')), findsOneWidget);
      expect(find.byKey(const ValueKey('trimEnd')), findsOneWidget);
      await t.drag(
        find.byKey(const ValueKey('trimStart')),
        const Offset(96, 0),
      );
      await _settle(t);
      expect(touches, 1);
      expect(grabbed, 1);
      expect(released, 1);
      expect(ranges, isNotEmpty);
      expect(ranges.last.$1, greaterThan(0));
      await t.tapAt(t.getCenter(find.byKey(const ValueKey('editTimeline'))));
      await _settle(t);
      expect(touches, 2);
    });
  });

  group('custom app icon', () {
    test('any photo becomes a 512 x 512 square', () async {
      final sq = await squareIcon(await _picture(300, 120));
      expect(await _size(sq), const Size(512, 512));
      final a = await adaptiveIcon(sq);
      expect(await _size(a), const Size(768, 768));
    });

    testWidgets('pick a photo and add it to the home screen', (t) async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (c) async {
            calls.add(c);
            switch (c.method) {
              case 'available':
                return true;
              case 'get':
                return 'classic';
              case 'pinCustom':
                return 'pinned';
            }
            return null;
          });
      final png = await t.runAsync(() => _picture(80, 60));
      debugPickIconPhoto = () async => png;
      addTearDown(() {
        debugPickIconPhoto = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, null);
      });
      await t.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(const MaterialApp(home: AppIconScreen()));
      await _settle(t);
      expect(find.byKey(const ValueKey('customIconAdd')), findsNothing);
      await t.runAsync(() async {
        await t.tap(find.byKey(const ValueKey('customIconPick')));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await _settle(t);
      expect(find.byKey(const ValueKey('customIconPreview')), findsOneWidget);
      await t.runAsync(() async {
        await t.tap(find.byKey(const ValueKey('customIconAdd')));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await _settle(t);
      final pin = calls.where((c) => c.method == 'pinCustom').single;
      final bytes = (pin.arguments as Map)['png'] as Uint8List;
      expect(
        base64Encode(bytes.sublist(1, 4)),
        base64Encode(utf8.encode('PNG')),
      );
      expect(find.textContaining('Add'), findsWidgets);
      await t.pump(const Duration(seconds: 4));
    });
  });
}
