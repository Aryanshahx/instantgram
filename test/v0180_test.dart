// v0.18.0: Hyper Intelligence (moderation core).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/config/app_info.dart';
import 'package:instantgram/core/services/api_client.dart';
import 'package:instantgram/core/services/bad_words.dart';
import 'package:instantgram/core/services/content_filter.dart';
import 'package:instantgram/core/services/hyper_intelligence.dart';
import 'package:instantgram/core/services/music_player.dart';
import 'package:instantgram/core/services/presence.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/post/presentation/comments_sheet.dart';
import 'package:instantgram/features/settings/presentation/hyper_intelligence_screen.dart';
import 'package:instantgram/features/stories/presentation/story_viewer_screen.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/widgets/hi_blur.dart';
import 'package:instantgram/shared/widgets/hi_text_check.dart';
import 'package:instantgram/shared/widgets/media_view.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:instantgram/shared/widgets/post_grid.dart';
import 'package:shared_preferences/shared_preferences.dart';

Post _post(
  String id, {
  String author = 'amit',
  bool sensitive = false,
  String state = 'ok',
  bool clip = false,
}) => Post.fromMap(id, {
  'authorId': author,
  'authorUsername': author,
  'type': clip ? 'clip' : 'photo',
  'mediaUrl': 'https://x/$id.jpg',
  'caption': 'hello',
  'sensitive': sensitive,
  'modState': state,
});

Comment _comment(String id, {bool sensitive = false, bool hidden = false}) =>
    Comment.fromMap(id, {
      'authorId': 'amit',
      'authorUsername': 'amit',
      'text': 'secret words',
      'sensitive': sensitive,
      'hidden': hidden,
    });

Story _story(String id, {bool sensitive = false, String author = 'riya'}) =>
    Story.fromMap(id, {
      'authorId': author,
      'authorUsername': author,
      'mediaUrl': 'https://x/$id.jpg',
      'mediaKey': 'story/$author/$id',
      'type': 'photo',
      'sensitive': sensitive,
    });

Future<void> _frames(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _finish(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 1));
}

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark,
  home: Scaffold(body: child),
);

void main() {
  final hi = HyperIntelligence.instance;

  setUpAll(() {
    NetImage.disableCache = true;
    MusicPlayer.disabled = true;
    Presence.instance.show.value = false;
    HyperIntelligence.retryWait = const Duration(milliseconds: 5);
  });

  setUp(() {
    ContentFilter.instance.debugSet(me: 'me');
    hi.debugSet();
    HyperIntelligence.debugPost = null;
    HyperIntelligence.debugFrame = null;
  });

  test('version is set (exact version: newest test file)', () {
    expect(AppInfo.version, matches(RegExp(r'^\d+\.\d+\.\d+$')));
  });

  group('BadWords', () {
    test('finds strong abuse in English, Hindi and Hinglish', () {
      for (final s in [
        'you fucker',
        'F.U.C.K this',
        'f u c k you',
        'fuuuuck',
        'FUCK',
        'what a 5lut',
        'total b1tch',
        'fuckboy99',
        'my_motherfucker_name',
        'tu madarchod hai',
        'bhenchod',
        'chutiya',
        'साला चूतिया',
        'मादरचोद',
        'please kill yourself',
        'Kill. Your. Self!!',
      ]) {
        expect(BadWords.find(s), isNotNull, reason: s);
      }
    });

    test('normal words are fine', () {
      for (final s in [
        '',
        'Hello world',
        'Scunthorpe United',
        'classic class assassin',
        'I visited Niger and Lund',
        'Gandhi ji',
        'पानी पीना है',
        'Shit happens? no: shoot happens',
        'cocktail party at Dickens road',
        'killing it at the gym',
        'k i l l',
      ]) {
        expect(BadWords.find(s), isNull, reason: s);
      }
    });

    test('mask', () {
      expect(BadWords.mask('fucker'), 'f*****');
      expect(BadWords.mask('चूत'), 'च**');
      expect(BadWords.mask('x'), '*');
    });
  });

  group('models', () {
    test('Post / Comment / Story read the Hyper Intelligence fields', () {
      final p = _post('p1', sensitive: true, state: 'hidden');
      expect(p.sensitive, isTrue);
      expect(p.modHidden, isTrue);
      expect(p.underReview, isTrue);
      expect(_post('p2').sensitive, isFalse);
      final c = _comment('c1', sensitive: true, hidden: true);
      expect(c.sensitive, isTrue);
      expect(c.hidden, isTrue);
      final s = _story('s1', sensitive: true);
      expect(s.sensitive, isTrue);
      expect(s.toHighlightItem()['sensitive'], isTrue);
      expect(_story('s2').toHighlightItem().containsKey('sensitive'), isFalse);
    });
  });

  group('decisions', () {
    test('blur mode: sensitive is blurred for others, never for me', () {
      final p = _post('p1', sensitive: true);
      expect(hi.blurs(p), isTrue);
      expect(hi.hides(p), isFalse);
      final mine = _post('p2', author: 'me', sensitive: true, state: 'hidden');
      expect(hi.blurs(mine), isFalse);
      expect(hi.hides(mine), isFalse);
      expect(hi.blurs(_post('p3')), isFalse);
      hi.reveal(p);
      expect(hi.blurs(p), isFalse);
    });

    test('hidden by the admin = gone for others', () {
      final p = _post('p1', state: 'hidden');
      expect(hi.hides(p), isTrue);
      expect(ContentFilter.instance.canSee(p), isFalse);
    });

    test('Hide mode and under 18 hide sensitive content', () {
      final p = _post('p1', sensitive: true);
      hi.debugSet(m: HyperIntelligence.hide);
      expect(hi.hides(p), isTrue);
      hi.debugSet(minor: true);
      expect(hi.hides(p), isTrue);
      expect(hi.hidesStory(_story('s1', sensitive: true)), isTrue);
      expect(hi.hidesComment(_comment('c1', sensitive: true)), isTrue);
      expect(ContentFilter.instance.canSee(p), isFalse);
    });

    test('feeds: sensitive posts only for followers of the author', () {
      final p = _post('p1', sensitive: true);
      expect(ContentFilter.instance.canSee(p), isTrue);
      expect(ContentFilter.instance.canSeeInFeeds(p), isFalse);
      ContentFilter.instance.debugSet(me: 'me', following: {'amit'});
      expect(ContentFilter.instance.canSeeInFeeds(p), isTrue);
      expect(
        ContentFilter.instance.canSeeInFeeds(
          _post('p2', author: 'me', sensitive: true),
        ),
        isTrue,
      );
    });

    test('version changes when the setting changes', () {
      final v = hi.version.value;
      hi.debugSet(m: HyperIntelligence.hide);
      expect(hi.version.value, greaterThan(v));
    });
  });

  group('checks', () {
    test('sends the right body and returns the state', () async {
      final sent = <Map<String, dynamic>>[];
      HyperIntelligence.debugPost = (b) async {
        sent.add(b);
        return {'state': 'review'};
      };
      expect(await hi.checkPost('p1', frames: ['data:a']), 'review');
      expect(await hi.checkMoment('m1'), 'review');
      expect(await hi.checkComment('p1', 'c1'), 'review');
      expect(sent[0], {
        'action': 'check',
        'kind': 'post',
        'id': 'p1',
        'frames': ['data:a'],
      });
      expect(sent[1], {'action': 'check', 'kind': 'moment', 'id': 'm1'});
      expect(sent[2], {
        'action': 'check',
        'kind': 'comment',
        'id': 'c1',
        'postId': 'p1',
      });
    });

    test('server error: tries twice, never throws', () async {
      var calls = 0;
      HyperIntelligence.debugPost = (b) async {
        calls++;
        throw ApiException('down', statusCode: 500);
      };
      expect(await hi.checkPost('p1'), '');
      expect(calls, 2);
    });

    test('4xx: does not try again', () async {
      var calls = 0;
      HyperIntelligence.debugPost = (b) async {
        calls++;
        throw ApiException('not yours', statusCode: 403);
      };
      expect(await hi.checkPost('p1'), '');
      expect(calls, 1);
    });

    test('frameTimes = 25 / 50 / 75 % of the shown part', () {
      expect(HyperIntelligence.frameTimes(0, 8000), [2000, 4000, 6000]);
      expect(HyperIntelligence.frameTimes(1000, 5000), [2000, 3000, 4000]);
      expect(HyperIntelligence.frameTimes(500, 500), [500]);
      expect(HyperIntelligence.frameTimes(-5, -5), [0]);
    });

    test('framesOf: trimmed part, skips failed pictures', () async {
      final asked = <int>[];
      HyperIntelligence.debugFrame = (path, ms) async {
        asked.add(ms);
        if (ms == 4000) throw StateError('no frame');
        if (ms == 5000) return null;
        return Uint8List.fromList([1, 2, 3]);
      };
      final out = await hi.framesOf(
        '/v.mp4',
        durationMs: 10000,
        edits: const VideoEdits(trimStartMs: 2000, trimEndMs: 6000),
      );
      expect(asked, [3000, 4000, 5000]);
      expect(out, ['data:image/jpeg;base64,AQID']);
    });
  });

  group('widgets', () {
    testWidgets('PostMedia: blurred until "Tap to view"', (t) async {
      final p = _post('p1', sensitive: true);
      await t.pumpWidget(_app(PostMedia(post: p)));
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('hi-blur-p1')), findsOneWidget);
      expect(find.text('Sensitive content'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('hi-reveal')));
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('hi-blur-p1')), findsNothing);
      expect(find.text('Sensitive content'), findsNothing);
      await _finish(t);
    });

    testWidgets('PostMedia: my sensitive post shows the owner pill', (t) async {
      final p = _post('p1', author: 'me', sensitive: true, state: 'hidden');
      await t.pumpWidget(_app(PostMedia(post: p)));
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('hi-blur-p1')), findsNothing);
      expect(find.byKey(const ValueKey('hi-owner-pill')), findsOneWidget);
      expect(find.text('Hidden · under review'), findsOneWidget);
      await _finish(t);
    });

    testWidgets('ClipCover: compact blurred tile', (t) async {
      await t.pumpWidget(
        _app(
          SizedBox(
            width: 120,
            height: 200,
            child: ClipCover(post: _post('c1', clip: true, sensitive: true)),
          ),
        ),
      );
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('hi-tile')), findsOneWidget);
      await t.pumpWidget(
        _app(
          SizedBox(
            width: 120,
            height: 200,
            child: ClipCover(post: _post('c2', clip: true)),
          ),
        ),
      );
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('hi-tile')), findsNothing);
      await _finish(t);
    });

    testWidgets('HiBlur calls onReveal', (t) async {
      var n = 0;
      await t.pumpWidget(_app(HiBlur(onReveal: () => n++)));
      await _frames(t, 2);
      expect(
        find.text(
          'Hyper Intelligence blurred this because it may be upsetting.',
        ),
        findsOneWidget,
      );
      await t.tap(find.byKey(const ValueKey('hi-reveal')));
      expect(n, 1);
      await _finish(t);
    });

    testWidgets('CommentTile: sensitive text hidden until tapped', (t) async {
      final c = _comment('c1', sensitive: true);
      await t.pumpWidget(
        _app(
          CommentTile(
            postId: 'p1',
            comment: c,
            canDelete: false,
            onReply: () {},
            onDelete: () {},
            likedStream: Stream.value(false),
          ),
        ),
      );
      await _frames(t, 2);
      expect(find.text('secret words'), findsNothing);
      expect(
        find.text('Hidden by Hyper Intelligence · Tap to view'),
        findsOneWidget,
      );
      await t.tap(find.byKey(const ValueKey('hi-comment-c1')));
      await _frames(t, 2);
      expect(find.text('secret words'), findsOneWidget);
      expect(
        find.text('Hidden by Hyper Intelligence · Tap to view'),
        findsNothing,
      );
      await _finish(t);
    });

    testWidgets('moment: blurred, timer waits, Tap to view starts it', (
      t,
    ) async {
      SharedPreferences.setMockInitialValues({});
      StoryViewerScreen.debugMe = 'me';
      StoryViewerScreen.debugRecordView = (st) async {};
      StoryViewerScreen.debugMyLike = (id) async => false;
      addTearDown(() {
        StoryViewerScreen.debugMe = null;
        StoryViewerScreen.debugRecordView = null;
        StoryViewerScreen.debugMyLike = null;
      });
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: StoryViewerScreen(
            groups: [
              StoryGroup('riya', [_story('s1', sensitive: true)]),
            ],
          ),
        ),
      );
      await _frames(t, 3);
      expect(find.byKey(const ValueKey('hi-moment')), findsOneWidget);
      // 8 s later it is still there (no timer = not skipped)
      await _frames(t, 80);
      expect(find.byKey(const ValueKey('hi-moment')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('hi-reveal')));
      await _frames(t, 3);
      expect(find.byKey(const ValueKey('hi-moment')), findsNothing);
      await _finish(t);
    });

    testWidgets('bad words dialog stops sending', (t) async {
      final results = <bool>[];
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  key: const ValueKey('bad'),
                  onPressed: () async => results.add(
                    await hiTextOk(context, ['ok', 'you fucker']),
                  ),
                  child: const Text('bad'),
                ),
                TextButton(
                  key: const ValueKey('good'),
                  onPressed: () async =>
                      results.add(await hiTextOk(context, ['nice pic'])),
                  child: const Text('good'),
                ),
              ],
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('good')));
      await _frames(t, 2);
      expect(results, [true]);
      expect(find.byKey(const ValueKey('hi-word-dialog')), findsNothing);
      await t.tap(find.byKey(const ValueKey('bad')));
      await _frames(t, 4);
      expect(find.byKey(const ValueKey('hi-word-dialog')), findsOneWidget);
      expect(find.textContaining('f*****'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('hi-word-ok')));
      await _frames(t, 4);
      expect(results, [true, false]);
      await _finish(t);
    });

    testWidgets('Settings page: Blur / Hide', (t) async {
      SharedPreferences.setMockInitialValues({});
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const HyperIntelligenceScreen(),
        ),
      );
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('hi-minor-note')), findsNothing);
      await t.runAsync(() async {
        await t.tap(find.byKey(const ValueKey('hi-mode-hide')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await _frames(t, 2);
      expect(hi.mode.value, HyperIntelligence.hide);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('hi_sensitive_mode'), 'hide');
      await t.runAsync(() async {
        await t.tap(find.byKey(const ValueKey('hi-mode-blur')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await _frames(t, 2);
      expect(hi.mode.value, HyperIntelligence.blur);
      await _finish(t);
    });

    testWidgets('Settings page: under 18 = always hidden', (t) async {
      hi.debugSet(minor: true);
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const HyperIntelligenceScreen(),
        ),
      );
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('hi-minor-note')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('hi-mode-blur')));
      await _frames(t, 2);
      expect(hi.mode.value, HyperIntelligence.blur);
      expect(hi.hides(_post('p1', sensitive: true)), isTrue);
      await _finish(t);
    });
  });
}
