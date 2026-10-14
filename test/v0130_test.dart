import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/services/account_status.dart';
import 'package:instantgram/core/services/chat_prefs.dart';
import 'package:instantgram/core/services/net_priority.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/chats/data/chat_repository.dart';
import 'package:instantgram/features/chats/presentation/chats_screen.dart';
import 'package:instantgram/features/editor/edit_models.dart';
import 'package:instantgram/features/editor/photo_render.dart';
import 'package:instantgram/features/notifications/presentation/notifications_screen.dart';
import 'package:instantgram/features/post/data/report_repository.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:instantgram/shared/widgets/stickers.dart';
import 'package:instantgram/shared/widgets/verified_badge.dart';

// v0.13: personal disappearing messages, typing, refresh priority,
// sticker pack, verified badge, reports, admin notices.

final _t0 = DateTime(2026, 10, 14, 12);
Timestamp _ts(int minutes) =>
    Timestamp.fromDate(_t0.add(Duration(minutes: minutes)));

Message _m(String id, {String sender = 'other', int at = 0}) => Message.fromMap(
  id,
  {'senderId': sender, 'text': 'hi $id', 'createdAt': _ts(at)},
);

Chat _chat({int updated = 0, String last = 'other', Map? typing, Map? seen}) {
  final m = <String, dynamic>{
    'members': ['me', 'other'],
    'lastSenderId': last,
    'lastMessage': 'x',
    'updatedAt': _ts(updated),
  };
  if (typing != null) m['typing'] = typing;
  if (seen != null) m['seen'] = seen;
  return Chat.fromMap('me_other', m);
}

/// Records drawImageRect calls (for paintSticker).
class _RecCanvas implements Canvas {
  Rect? dst;
  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) =>
      this.dst = dst;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  setUpAll(() => NetImage.disableCache = true);

  group('NetPriority (pull to refresh first)', () {
    test('busy while a refresh runs, quiet after', () async {
      expect(NetPriority.quiet, isFalse);
      final gate = Completer<void>();
      final f = NetPriority.run(() => gate.future);
      expect(NetPriority.quiet, isTrue);
      var waited = false;
      final w = NetPriority.waitQuiet().then((_) => waited = true);
      await Future<void>.delayed(Duration.zero);
      expect(waited, isFalse, reason: 'background work waits');
      gate.complete();
      await f;
      await w;
      expect(waited, isTrue);
      expect(NetPriority.quiet, isFalse);
    });

    test(
      'refresh -> true / false (error or timeout), never stuck busy',
      () async {
        expect(await NetPriority.refresh(() async {}), isTrue);
        expect(
          await NetPriority.refresh(() async => throw Exception('net')),
          isFalse,
        );
        expect(
          await NetPriority.refresh(
            () => Future<void>.delayed(const Duration(seconds: 2)),
            timeout: const Duration(milliseconds: 20),
          ),
          isFalse,
        );
        expect(NetPriority.quiet, isFalse);
      },
    );
  });

  group('Disappearing messages: only for me', () {
    final since = _t0.add(const Duration(minutes: 10));
    final all = [
      _m('old', at: 0), // before I switched it on: stays
      _m('new', at: 20),
      _m('mine', sender: 'me', at: 30),
    ];

    test('24h: only messages since it was turned on, after 24 hours', () {
      final soon = ChatRepository.visible(
        all,
        me: 'me',
        now: _t0.add(const Duration(hours: 2)),
        vanishMode: Disappear.day,
        vanishSince: since,
      );
      expect(soon.map((m) => m.id), ['old', 'new', 'mine']);
      final later = ChatRepository.visible(
        all,
        me: 'me',
        now: _t0.add(const Duration(hours: 30)),
        vanishMode: Disappear.day,
        vanishSince: since,
      );
      expect(later.map((m) => m.id), ['old']);
    });

    test('once seen: gone after I saw them; off = nothing changes', () {
      final seen = ChatRepository.visible(
        all,
        me: 'me',
        now: _t0.add(const Duration(hours: 1)),
        seenBefore: _t0.add(const Duration(minutes: 25)),
        vanishMode: Disappear.seen,
        vanishSince: since,
      );
      expect(seen.map((m) => m.id), ['old', 'mine']);
      final off = ChatRepository.visible(
        all,
        me: 'me',
        now: _t0.add(const Duration(days: 30)),
        seenBefore: _t0.add(const Duration(minutes: 25)),
      );
      expect(off.length, 3);
    });

    test('my setting is saved per chat (with the time it was turned on)', () {
      final p = ChatPrefsData(vanish: {'me_other': (Disappear.week, since)});
      expect(p.vanishMode('me_other'), Disappear.week);
      expect(p.vanishSince('me_other'), since);
      expect(p.vanishMode('me_x'), Disappear.off);
      expect(p.vanishSince('me_x'), isNull);
    });

    test('chat list: "Messages disappeared" only on my side', () {
      final p = ChatPrefsData(vanish: {'me_other': (Disappear.day, since)});
      final chat = _chat(updated: 20);
      expect(
        vanishedForMe(chat, 'me', p, now: _t0.add(const Duration(hours: 1))),
        isFalse,
      );
      expect(
        vanishedForMe(chat, 'me', p, now: _t0.add(const Duration(hours: 26))),
        isTrue,
      );
      expect(
        vanishedForMe(
          chat,
          'me',
          const ChatPrefsData(),
          now: _t0.add(const Duration(days: 9)),
        ),
        isFalse,
      );
      // last message from before it was on: stays
      expect(
        vanishedForMe(
          _chat(updated: 0),
          'me',
          p,
          now: _t0.add(const Duration(days: 9)),
        ),
        isFalse,
      );
    });
  });

  group('Typing', () {
    test('isTyping: fresh time only, per person', () {
      final chat = _chat(typing: {'other': _ts(0)});
      expect(
        chat.isTyping('other', _t0.add(const Duration(seconds: 3))),
        isTrue,
      );
      expect(
        chat.isTyping(
          'other',
          _t0.add(Chat.typingFor + const Duration(seconds: 1)),
        ),
        isFalse,
      );
      expect(chat.isTyping('me', _t0), isFalse);
      expect(_chat().isTyping('other', _t0), isFalse);
    });
  });

  group('Sticker pack', () {
    test('ids, texts and files', () {
      expect(StickerPack.ids.length, greaterThanOrEqualTo(40));
      expect(StickerPack.ids.toSet().length, StickerPack.ids.length);
      for (final id in StickerPack.ids) {
        final t = StickerPack.textFor(id);
        expect(StickerPack.isPack(t), isTrue);
        expect(StickerPack.idOf(t), id);
        expect(StickerPack.assetFor(t), 'assets/stickers/$id.png');
        expect(
          File('assets/stickers/$id.png').existsSync(),
          isTrue,
          reason: id,
        );
      }
      expect(StickerPack.isPack('😀'), isFalse);
      expect(
        StickerPack.minSize < StickerPack.defaultSize &&
            StickerPack.defaultSize < StickerPack.maxSize,
        isTrue,
      );
    });

    test('saved stickers keep their (bigger) size', () {
      final o = VideoOverlay.fromMap({
        'k': VideoOverlay.stickerKind,
        't': StickerPack.textFor(StickerPack.ids.first),
        'z': 0.9,
      })!;
      expect(o.size, 0.9);
      expect(o.isSticker, isTrue);
      final big = VideoOverlay.fromMap({'k': 'text', 't': 'x', 'z': 5})!;
      expect(big.size, 0.95);
    });

    test(
      'paintSticker: width = size x frame, centred on the position',
      () async {
        final rec = ui.PictureRecorder();
        Canvas(rec).drawRect(
          const Rect.fromLTWH(0, 0, 100, 50),
          Paint()..color = Colors.red,
        );
        final img = await rec.endRecording().toImage(100, 50);
        final c = _RecCanvas();
        paintSticker(
          c,
          img,
          TextLayer(
            text: StickerPack.textFor('wow'),
            size: 0.5,
            pos: const Offset(0.5, 0.25),
            sticker: true,
          ),
          400,
          300,
        );
        expect(
          c.dst,
          Rect.fromCenter(
            center: const Offset(200, 75),
            width: 200,
            height: 100,
          ),
        );
        img.dispose();
      },
    );

    testWidgets('StickerImage shows the picture', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Center(
            child: StickerImage(text: StickerPack.textFor('wow'), width: 80),
          ),
        ),
      );
      await t.pump();
      final img = t.widget<Image>(find.byType(Image));
      expect(img.width, 80);
      expect((img.image as AssetImage).assetName, 'assets/stickers/wow.png');
    });
  });

  group('Admin website: badge, reports, notices', () {
    test('verified list from config/verified', () {
      expect(AccountStatus.uidsOf(null), isEmpty);
      expect(AccountStatus.uidsOf({'uids': 'x'}), isEmpty);
      expect(
        AccountStatus.uidsOf({
          'uids': ['a', '', 3, 'b'],
        }),
        {'a', 'b'},
      );
    });

    testWidgets('VerifiedBadge only for verified accounts', (t) async {
      AccountStatus.instance.debugSetVerified({'u1'});
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: Column(
              children: [
                VerifiedBadge(uid: 'u1'),
                VerifiedBadge(uid: 'u2'),
              ],
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('verified-badge')), findsOneWidget);
      AccountStatus.instance.debugSetVerified({});
      await t.pump();
      expect(find.byKey(const ValueKey('verified-badge')), findsNothing);
      expect(AccountStatus.instance.isVerified(''), isFalse);
    });

    test('report data: known kinds, short texts', () {
      final d = ReportRepository.reportData(
        kind: 'weird',
        reporterUid: 'me',
        reporterUsername: 'x' * 99,
        reason: 'r' * 200,
        message: '  ${'m' * 3000}  ',
      );
      expect(d['kind'], 'post');
      expect((d['reporterUsername'] as String).length, 40);
      expect((d['reason'] as String).length, 80);
      expect((d['message'] as String).length, 2000);
      expect(d.keys.toSet(), {
        'kind',
        'reporterUid',
        'reporterUsername',
        'targetId',
        'postId',
        'targetUid',
        'reason',
        'message',
      });
      expect(
        ReportRepository.reportData(kind: 'comment', reporterUid: 'me')['kind'],
        'comment',
      );
    });

    test('notice text in the notifications list', () {
      final n = AppNotification(
        id: 'n1',
        type: AppNotification.notice,
        fromUid: '',
        fromUsername: 'InstantGram',
        fromPhotoUrl: '',
        postId: '',
        postThumb: '',
        text: 'Hello from the team',
        read: false,
        createdAt: _t0,
      );
      expect(notificationText(n), 'Hello from the team');
    });
  });
}
