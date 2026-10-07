import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/music.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/services/call_engine.dart';
import 'package:instantgram/widgets/music_widgets.dart';
import 'package:instantgram/widgets/reel_actions.dart';

Post _post(List<PostItem> media, {String musicId = ''}) => Post(
  id: 'p',
  authorId: 'u',
  authorUsername: 'user',
  authorPhotoUrl: '',
  type: 'image',
  caption: 'c',
  createdAt: DateTime(2026, 1, 1),
  imageRef: media.isEmpty ? '' : media.first.ref,
  media: media,
  musicId: musicId,
);

void main() {
  group('carousel items', () {
    test('an item survives the trip to the database and back', () {
      const v = PostItem(
        video: true,
        ref: 'm:v1',
        thumbRef: 'm:t1',
        width: 1080,
        height: 1920,
        seconds: 12,
      );
      final back = PostItem.fromMap(v.toMap())!;
      expect(back.video, isTrue);
      expect(back.ref, 'm:v1');
      expect(back.thumbRef, 'm:t1');
      expect((back.width, back.height, back.seconds), (1080, 1920, 12));
      const p = PostItem(video: false, ref: 'm:p1');
      expect(p.toMap(), {'t': 'image', 'u': 'm:p1'});
      expect(PostItem.fromMap(p.toMap())!.video, isFalse);
    });

    test('broken entries are skipped', () {
      expect(PostItem.fromMap(null), isNull);
      expect(PostItem.fromMap({'t': 'image'}), isNull);
      expect(PostItem.fromMap('x'), isNull);
    });

    test('one item is a plain post, two or more a carousel', () {
      const a = PostItem(video: false, ref: 'm:a');
      const b = PostItem(video: true, ref: 'm:b', thumbRef: 'm:bt');
      expect(_post(const []).isCarousel, isFalse);
      expect(_post(const [a]).isCarousel, isFalse);
      final c = _post(const [a, b]);
      expect(c.isCarousel, isTrue);
      expect(c.media.length, 2);
      expect(c.isVideo, isFalse); // a carousel stays a photo post
    });

    test('limits', () {
      expect(kMaxPostItems, 10);
      expect(kPhotoClipSeconds, 5);
    });
  });

  group('music names', () {
    test('a remote track shows title and artist', () {
      rememberMusic('ov:abc', 'Night Drive', 'Some Artist');
      final t = musicById('ov:abc')!;
      expect(t.label, contains('Night Drive'));
      expect(t.label, contains('Some Artist'));
      expect(t.label.contains('ov:'), isFalse);
    });

    test('a library track has just its title', () {
      final t = kMusicLibrary.first;
      expect(t.label, t.title);
    });

    testWidgets('the label under a username shows the track', (t) async {
      rememberMusic('ov:xyz', 'Slow Burn', 'Band');
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: MusicLabel(musicId: 'ov:xyz')),
        ),
      );
      expect(find.textContaining('Slow Burn'), findsOneWidget);
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: MusicLabel(musicId: '')),
        ),
      );
      expect(find.byType(Text), findsNothing);
    });
  });

  group('call failure messages', () {
    test('rules not published', () {
      final m = callFailureMessage(
        FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
      );
      expect(m, contains('Firestore'));
      expect(m, contains('Publish'));
    });

    test('offline', () {
      final m = callFailureMessage(
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
      );
      expect(m, contains('internet'));
    });

    test('bad Agora App ID', () {
      final m = callFailureMessage(AgoraRtcException(code: -101));
      expect(m, contains('App ID'));
    });

    test('anything else says what it was', () {
      final m = callFailureMessage(Exception('boom'));
      expect(m, contains('boom'));
      expect(m, startsWith('Could not start the call'));
    });
  });

  test(
    'report email goes to the support address, spaces are not plus signs',
    () {
      final u = reportUri(_post(const []));
      expect(u.scheme, 'mailto');
      expect(u.path, 'techlabs.hyper@gmail.com');
      expect(u.queryParameters['subject'], 'Report: post p');
      expect(
        u.queryParameters['body'],
        contains('I want to report this post.'),
      );
      expect(u.toString().contains('+'), isFalse);
    },
  );
}
