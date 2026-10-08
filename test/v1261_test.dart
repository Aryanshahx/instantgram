import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/models/app_user.dart';
import 'package:instantgram/services/presence_service.dart';
import 'package:instantgram/widgets/live_presence.dart';
import 'package:instantgram/widgets/pull_hold.dart';

void main() {
  tearDown(() => debugPresenceStream = null);

  group('active status', () {
    final now = DateTime(2026, 10, 9, 12);

    test('leaving the app ends "Active now" at once', () {
      final justNow = now.subtract(const Duration(seconds: 10));
      expect(isActiveNow(justNow, now), isTrue);
      expect(isActiveNow(justNow, now, online: false), isFalse);
      expect(presenceLabel(justNow, now, online: false), 'Active just now');
      expect(
        presenceLabel(
          now.subtract(const Duration(minutes: 3)),
          now,
          online: false,
        ),
        'Active 3m ago',
      );
    });

    test('a phone that stops beating drops out within the window', () {
      expect(kPresenceBeat, const Duration(minutes: 2));
      expect(
        isActiveNow(now.subtract(const Duration(minutes: 5)), now),
        isFalse,
      );
    });

    test('old app versions (no online field) count as online', () {
      expect(const AppUser(uid: 'u', username: 'u').online, isTrue);
    });

    testWidgets('the label follows the live profile', (t) async {
      final live = StreamController<AppUser?>();
      debugPresenceStream = (_) => live.stream;
      await t.pumpWidget(
        MaterialApp(
          home: LivePresence(
            uid: 'zoe',
            initial: AppUser(
              uid: 'zoe',
              username: 'zoe',
              lastActive: DateTime.now(),
            ),
            builder: (_, u) => Text(
              presenceLabel(
                u?.lastActive,
                DateTime.now(),
                online: u?.online ?? true,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Active now'), findsOneWidget);
      live.add(
        AppUser(
          uid: 'zoe',
          username: 'zoe',
          lastActive: DateTime.now(),
          online: false,
        ),
      );
      await t.pump();
      await t.pump();
      expect(find.text('Active just now'), findsOneWidget);
      live.add(
        AppUser(uid: 'zoe', username: 'zoe', lastActive: DateTime.now()),
      );
      await t.pump();
      await t.pump();
      expect(find.text('Active now'), findsOneWidget);
      await live.close();
    });
  });

  testWidgets('slide up and hold at the newest message of a long chat', (
    t,
  ) async {
    var fired = 0;
    final pull = PullHold(onFire: () => fired++);
    addTearDown(pull.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotificationListener<ScrollNotification>(
            onNotification: pull.handle,
            child: ListView.builder(
              key: const ValueKey('list'),
              reverse: true,
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: 60,
              itemBuilder: (_, i) => SizedBox(height: 60, child: Text('m$i')),
            ),
          ),
        ),
      ),
    );
    // sliding down first only scrolls back through older messages
    var g = await t.startGesture(
      t.getCenter(find.byKey(const ValueKey('list'))),
    );
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(0, 30));
      await t.pump(const Duration(milliseconds: 16));
    }
    await t.pump(const Duration(milliseconds: 900));
    await g.up();
    await t.pumpAndSettle();
    expect(fired, 0);

    // back at the newest message, slide up and hold
    await t.drag(find.byKey(const ValueKey('list')), const Offset(0, -2000));
    await t.pumpAndSettle();
    g = await t.startGesture(t.getCenter(find.byKey(const ValueKey('list'))));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(0, -20));
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(pull.progress.value, 1);
    await t.pump(const Duration(milliseconds: 700));
    expect(fired, 1);
    await g.up();
    await t.pump();
  });
}
