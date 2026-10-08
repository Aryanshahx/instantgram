import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/audio_edits.dart';
import 'package:instantgram/models/chat.dart';
import 'package:instantgram/models/vanish.dart';
import 'package:instantgram/screens/chat/chat_screen.dart'
    show kUserNotAvailable;
import 'package:instantgram/screens/chat/vanish_sheet.dart';
import 'package:instantgram/screens/post/video_editor_screen.dart';
import 'package:instantgram/services/audio_merger.dart';
import 'package:instantgram/services/presence_service.dart';
import 'package:instantgram/widgets/pull_hold.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark,
  home: Scaffold(body: child),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// A reversed list, like the chat, wired to a [PullHold].
Widget _chatList(PullHold pull, {int items = 3}) => _app(
  NotificationListener<ScrollNotification>(
    onNotification: pull.handle,
    child: ListView.builder(
      key: const ValueKey('list'),
      reverse: true,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: items,
      itemBuilder: (_, i) => SizedBox(height: 60, child: Text('m$i')),
    ),
  ),
);

void main() {
  // ------------------------------------------------------------- audio tools
  group('editor sound', () {
    test(
      'the song follows the clip: trim, speed and a short song that loops',
      () {
        expect(songPositionFor(videoSec: 5), 5);
        expect(songPositionFor(videoSec: 5, trimStart: 2, songStart: 10), 13);
        expect(songPositionFor(videoSec: 1, trimStart: 2, songStart: 10), 10);
        // half speed: the clip lasts twice as long, the song plays normally
        expect(songPositionFor(videoSec: 4, speed: 0.5), 8);
        expect(songPositionFor(videoSec: 4, speed: 2), 2);
        // a 12 s song starting at 2 s loops over its last 10 s
        expect(songPositionFor(videoSec: 15, songStart: 2, songLength: 12), 7);
        expect(songIsOff(5.1, 5), isFalse);
        expect(songIsOff(5.5, 5), isTrue);
        expect(speedLabel(0.5), '0.5x');
        expect(speedLabel(2), '2x');
      },
    );

    test('AudioEdits: defaults, clamping, voiceover', () {
      expect(AudioEdits.none.isDefault, isTrue);
      expect(AudioEdits.none.needsMix, isFalse);
      final e = AudioEdits.none.copyWith(
        songVolume: 3,
        fadeIn: 9,
        originalVolume: -1,
        voicePath: '/v.m4a',
      );
      expect(e.songVolume, 1);
      expect(e.fadeIn, AudioEdits.maxFade);
      expect(e.originalVolume, 0);
      expect(e.hasVoice, isTrue);
      expect(e.needsMix, isTrue);
      expect(e.withoutVoice().hasVoice, isFalse);
      expect(
        AudioEdits.none.copyWith(songStart: 4),
        const AudioEdits(songStart: 4),
      );
    });

    test('VideoEdits: how long the clip plays with a speed', () {
      const v = VideoEdits(start: 2, end: 12, total: 20, speed: 2, turns: 1);
      expect(v.length, 10);
      expect(v.playSeconds, 5);
      expect(v.rotated, isTrue);
      expect(v.isEmpty, isFalse);
      expect(
        const VideoEdits(start: 0, end: 10, total: 10, speed: 0.5).playSeconds,
        20,
      );
      expect(
        const VideoEdits(start: 0, end: 10, total: 10, turns: 4).isEmpty,
        isTrue,
      );
    });

    test('AudioMerger.mix passes every setting to the mixer', () async {
      Map<String, Object?>? got;
      AudioMerger.mixBackend = (a) async {
        got = a;
        return 7.5;
      };
      addTearDown(() => AudioMerger.mixBackend = null);
      final r = await AudioMerger.mix(
        video: File('/v.mp4'),
        song: File('/s.m4a'),
        songStart: 3,
        songVolume: 0.5,
        originalVolume: 0.2,
        voice: File('/voice.m4a'),
        fadeIn: 1,
        speed: 2,
        turns: 5,
      );
      expect(r.seconds, 7.5);
      expect(got!['song'], '/s.m4a');
      expect(got!['voice'], '/voice.m4a');
      expect(got!['songStart'], 3);
      expect(got!['songGain'], 0.5);
      expect(got!['origGain'], 0.2);
      expect(got!['speed'], 2);
      expect(got!['turns'], 1);
      expect(got!['cutToSong'], isTrue);
      await AudioMerger.mix(video: File('/v.mp4'), voice: File('/x.m4a'));
      expect(got!['cutToSong'], isFalse); // no song: nothing to cut to
    });
  });

  // --------------------------------------------------------------- presence
  group('presence', () {
    final now = DateTime(2026, 10, 8, 12);
    test('labels', () {
      expect(presenceLabel(null, now), '');
      expect(
        presenceLabel(now.subtract(const Duration(minutes: 2)), now),
        'Active now',
      );
      expect(
        isActiveNow(now.subtract(const Duration(minutes: 2)), now),
        isTrue,
      );
      expect(
        isActiveNow(now.subtract(const Duration(minutes: 7)), now),
        isFalse,
      );
      expect(
        presenceLabel(now.subtract(const Duration(minutes: 12)), now),
        'Active 12m ago',
      );
      expect(
        presenceLabel(now.subtract(const Duration(hours: 3)), now),
        'Active 3h ago',
      );
      expect(
        presenceLabel(now.subtract(const Duration(hours: 30)), now),
        'Active yesterday',
      );
      expect(
        presenceLabel(now.subtract(const Duration(days: 4)), now),
        'Active 4d ago',
      );
      expect(presenceLabel(now.subtract(const Duration(days: 9)), now), '');
    });
    test('the heartbeat keeps people "active now" while the app is open', () {
      expect(kPresenceBeat < kActiveNowWindow, isTrue);
    });
  });

  // ------------------------------------------------------ deleted accounts
  test('a deleted account is shown as "User not available"', () {
    expect(kUserNotAvailable, 'User not available');
  });

  // -------------------------------------------------- disappearing messages
  group('disappearing messages', () {
    final now = DateTime(2026, 10, 8, 12);

    test('modes, timers and the note in the chat', () {
      expect(Vanish.all, ['', 'seen', '24h', '7d']);
      expect(Vanish.isValid('24h'), isTrue);
      expect(Vanish.isValid('1h'), isFalse);
      expect(Vanish.label(Vanish.off), 'Off');
      expect(Vanish.label(Vanish.seen), 'After seen');
      expect(
        Vanish.expireAt(Vanish.day, now),
        now.add(const Duration(hours: 24)),
      );
      expect(
        Vanish.expireAt(Vanish.week, now),
        now.add(const Duration(days: 7)),
      );
      expect(Vanish.expireAt(Vanish.seen, now), isNull);
      expect(Vanish.expireAt(Vanish.off, now), isNull);
      expect(
        Vanish.systemText('aryan', Vanish.day),
        'aryan turned on disappearing messages (24 hours)',
      );
      expect(
        Vanish.systemText('aryan', Vanish.off),
        'aryan turned off disappearing messages',
      );
    });

    test('a message is hidden once its time is up', () {
      final m = ChatMessage(
        id: 'a',
        senderId: 'u',
        text: 'hi',
        createdAt: now,
        vanish: Vanish.day,
        expireAt: now.add(const Duration(hours: 24)),
      );
      expect(m.expired(now), isFalse);
      expect(m.expired(now.add(const Duration(hours: 24))), isTrue);
      expect(
        ChatMessage(
          id: 'b',
          senderId: 'u',
          text: 'x',
          createdAt: now,
        ).expired(now),
        isFalse,
      );
      expect(MsgType.all, contains(MsgType.system));
      expect(messagePreview(MsgType.system, 'note'), 'note');
    });

    testWidgets(
      'slide up and hold opens the picker; a short slide or letting go does not',
      (tester) async {
        var fired = 0;
        final pull = PullHold(onFire: () => fired++);
        addTearDown(pull.dispose);
        await tester.pumpWidget(_chatList(pull));

        // pull far and hold
        var g = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('list'))),
        );
        for (var i = 0; i < 10; i++) {
          await g.moveBy(const Offset(0, -20));
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(pull.progress.value, 1);
        await tester.pump(const Duration(milliseconds: 700));
        expect(fired, 1);
        await g.up();
        await tester.pump();

        // pull far but let go at once
        g = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('list'))),
        );
        for (var i = 0; i < 10; i++) {
          await g.moveBy(const Offset(0, -20));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await g.up();
        await tester.pump(const Duration(milliseconds: 900));
        expect(fired, 1);
        expect(pull.progress.value, 0);

        // a small pull, held
        g = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('list'))),
        );
        await g.moveBy(const Offset(0, -20));
        await tester.pump(const Duration(milliseconds: 16));
        await g.moveBy(const Offset(0, -20));
        await tester.pump(const Duration(milliseconds: 900));
        expect(fired, 1);
        await g.up();
        await tester.pump();

        // sliding down (towards older messages) never counts
        g = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('list'))),
        );
        for (var i = 0; i < 10; i++) {
          await g.moveBy(const Offset(0, 20));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.pump(const Duration(milliseconds: 900));
        expect(fired, 1);
        await g.up();
        await tester.pump();
      },
    );

    testWidgets('the picker shows the current mode and returns the new one', (
      tester,
    ) async {
      String? picked = 'none';
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  picked = await showVanishPicker(context, current: Vanish.day),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await _settle(tester);
      expect(find.text('Disappearing messages'), findsOneWidget);
      for (final k in [
        'vanish_off',
        'vanish_seen',
        'vanish_24h',
        'vanish_7d',
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget);
      }
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('vanish_24h')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('vanish_seen')));
      await _settle(tester);
      expect(picked, Vanish.seen);

      await tester.tap(find.text('open'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('vanish_off')));
      await _settle(tester);
      expect(picked, Vanish.off);
    });
  });
}
