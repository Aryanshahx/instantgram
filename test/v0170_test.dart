// v0.17 tests: hashtags you can tap + hashtag page, cover from video
// frames, must-allow page (notifications + lock screen calls), no app
// update / test ring.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/auth/presentation/permission_gate.dart';
import 'package:instantgram/features/post/data/post_repository.dart';
import 'package:instantgram/features/post/presentation/create_post_screen.dart';
import 'package:instantgram/features/search/presentation/hashtag_screen.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:instantgram/shared/widgets/tagged_text.dart';

Post _post(String id, {bool clip = false}) => Post.fromMap(id, {
  'authorId': 'amit',
  'authorUsername': 'amit',
  'type': clip ? 'clip' : 'photo',
  'mediaUrl': 'https://x/$id.jpg',
  'caption': '#goa',
  'tags': ['goa'],
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

/// Taps the span with [text] inside a [TaggedText].
void _tapSpan(WidgetTester t, String text) {
  final rich = t.widget<RichText>(
    find.descendant(
      of: find.byType(TaggedText),
      matching: find.byType(RichText),
    ),
  );
  var done = false;
  rich.text.visitChildren((s) {
    if (s is TextSpan && s.text == text && s.recognizer != null) {
      (s.recognizer! as TapGestureRecognizer).onTap!();
      done = true;
      return false;
    }
    return true;
  });
  expect(done, isTrue, reason: 'no tap on "$text"');
}

void main() {
  setUpAll(() => NetImage.disableCache = true);

  // -------------------------------------------------------------- hashtags
  group('hashtags', () {
    test('tags are saved the same way they are searched', () {
      expect(PostRepository.normalizeTag('#Goa '), 'goa');
      expect(PostRepository.normalizeTag('##Holi2026'), 'holi2026');
      expect(PostRepository.normalizeTag('#'), '');
      expect(PostRepository.extractTags('Fun at #Goa and #गोवा #goa'), [
        'goa',
        'गोवा',
      ]);
      final m = TaggedText.tagRe.allMatches('a #Goa_trip, #गोवा!').toList();
      expect(m.map((x) => x.group(1)), ['Goa_trip', 'गोवा']);
    });

    testWidgets('caption: tags lime + tappable, other text not', (t) async {
      final tapped = <String>[];
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: TaggedText(
              'Sunset at #Goa with #friends',
              prefix: const [TextSpan(text: 'amit ')],
              onTag: tapped.add,
            ),
          ),
        ),
      );
      _tapSpan(t, '#Goa');
      _tapSpan(t, '#friends');
      expect(tapped, ['Goa', 'friends']);
      final rich = t.widget<RichText>(
        find.descendant(
          of: find.byType(TaggedText),
          matching: find.byType(RichText),
        ),
      );
      expect(rich.text.toPlainText(), 'amit Sunset at #Goa with #friends');
      await _finish(t);
    });

    testWidgets('comment: @name at the start is lime too', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: TaggedText('@riya look #wow', mentionAtStart: true),
          ),
        ),
      );
      final rich = t.widget<RichText>(
        find.descendant(
          of: find.byType(TaggedText),
          matching: find.byType(RichText),
        ),
      );
      final spans = <TextSpan>[];
      rich.text.visitChildren((s) {
        if (s is TextSpan && s.text != null) spans.add(s);
        return true;
      });
      expect(spans.first.text, '@riya');
      expect(spans.first.style, TaggedText.tagStyle);
      expect(spans.first.recognizer, isNull);
      await _finish(t);
    });

    testWidgets('tap a tag -> hashtag page with clips and posts', (t) async {
      String? asked;
      HashtagScreen.debugLoad = (tag) async {
        asked = tag;
        return [_post('c1', clip: true), _post('p1'), _post('c2', clip: true)];
      };
      addTearDown(() => HashtagScreen.debugLoad = null);
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: TaggedText('Trip to #Goa')),
        ),
      );
      _tapSpan(t, '#Goa');
      await _frames(t, 8);
      expect(asked, 'goa');
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('#goa')),
        findsOneWidget,
      );
      expect(find.text('3 shares'), findsOneWidget);
      expect(find.text('Clips 2'), findsOneWidget);
      expect(find.text('Posts 1'), findsOneWidget);
      expect(find.byKey(const ValueKey('grid-c1')), findsOneWidget);
      expect(find.byKey(const ValueKey('grid-p1')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('tag-show-posts')));
      await _frames(t, 3);
      expect(find.byKey(const ValueKey('grid-p1')), findsOneWidget);
      expect(find.byKey(const ValueKey('grid-c1')), findsNothing);
      await t.tap(find.byKey(const ValueKey('tag-show-clips')));
      await _frames(t, 3);
      expect(find.byKey(const ValueKey('grid-c1')), findsOneWidget);
      expect(find.byKey(const ValueKey('grid-p1')), findsNothing);
      await _finish(t);
    });

    testWidgets('empty tag page + retry after an error', (t) async {
      var fail = true;
      HashtagScreen.debugLoad = (tag) async {
        if (fail) throw StateError('offline');
        return [];
      };
      addTearDown(() => HashtagScreen.debugLoad = null);
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const HashtagScreen(tag: 'none'),
        ),
      );
      await _frames(t, 3);
      expect(find.byKey(const ValueKey('tag-retry')), findsOneWidget);
      fail = false;
      await t.tap(find.byKey(const ValueKey('tag-retry')));
      await _frames(t, 3);
      expect(find.text('Nothing with #none yet'), findsOneWidget);
      await _finish(t);
    });

    test('captions + comments use tappable tags', () {
      for (final f in [
        'lib/features/feed/presentation/widgets/post_card.dart',
        'lib/features/reels/presentation/clips_screen.dart',
        'lib/features/post/presentation/comments_sheet.dart',
      ]) {
        expect(
          File(f).readAsStringSync().contains('TaggedText('),
          isTrue,
          reason: f,
        );
      }
    });
  });

  // ---------------------------------------------------- cover from frames
  group('cover from video frames', () {
    test('frame times are spread over the trimmed part', () {
      final a = CoverPickerScreen.frameTimes(0, 10000);
      expect(a.length, CoverPickerScreen.frameCount);
      expect(a.first, 0);
      expect(a.last, 9900);
      for (var i = 1; i < a.length; i++) {
        expect(a[i] > a[i - 1], isTrue);
      }
      expect(CoverPickerScreen.frameTimes(500, 500), [500]);
      expect(CoverPickerScreen.frameTimes(1000, 1050), [1000]);
      final b = CoverPickerScreen.frameTimes(2000, 6000, 3);
      expect(b, [2000, 3950, 5900]);
    });

    testWidgets('tap a frame, Done returns its time (no slider)', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.5;
      addTearDown(t.view.reset);
      final png = Uint8List.fromList(
        img.encodePng(img.Image(width: 9, height: 16)),
      );
      final asked = <int>[];
      CoverPickerScreen.debugNoVideo = true;
      CoverPickerScreen.debugFrame = (path, ms) async {
        asked.add(ms);
        return png;
      };
      addTearDown(() {
        CoverPickerScreen.debugNoVideo = false;
        CoverPickerScreen.debugFrame = null;
      });
      int? picked;
      final item = EditedMedia(
        file: File('/tmp/none.mp4'),
        isVideo: true,
        aspectRatio: 9 / 16,
        durationMs: 10000,
        edits: const VideoEdits(trimStartMs: 1000, trimEndMs: 5000),
      );
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (c) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  picked = await Navigator.of(c).push<int>(
                    MaterialPageRoute(
                      builder: (_) => CoverPickerScreen(item: item),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await _frames(t, 10);
      // v0.19: frames + a slider
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byKey(const ValueKey('cover-frames')), findsOneWidget);
      final times = CoverPickerScreen.frameTimes(1000, 5000);
      expect(asked, times, reason: 'one frame each, in order');
      expect(find.byKey(const ValueKey('cover-frame-0')), findsOneWidget);
      // the big preview shows the chosen frame
      expect(find.byType(Image), findsWidgets);
      await t.scrollUntilVisible(
        find.byKey(const ValueKey('cover-frame-5')),
        80,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('cover-frames')),
          matching: find.byType(Scrollable),
        ),
      );
      await t.tap(find.byKey(const ValueKey('cover-frame-5')));
      await _frames(t, 3);
      await t.tap(find.byKey(const ValueKey('cover-done')));
      await _frames(t, 6);
      expect(picked, times[5]);
      await _finish(t);
    });
  });

  // ------------------------------------------------- must-allow permissions
  group('must allow notifications + lock screen calls', () {
    tearDown(() {
      PermissionGate.debugCheck = null;
      PermissionGate.debugAskNotifications = null;
      PermissionGate.debugAskLockScreen = null;
      PermissionGate.debugReset();
    });

    testWidgets('all allowed -> the app opens', (t) async {
      PermissionGate.debugCheck = () async =>
          (notifications: true, lockScreen: true);
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const PermissionGate(child: Text('THE APP')),
        ),
      );
      await _frames(t, 2);
      expect(find.text('THE APP'), findsOneWidget);
      expect(find.byKey(const ValueKey('permission-gate')), findsNothing);
      await _finish(t);
    });

    testWidgets('blocked until both are allowed (no skip)', (t) async {
      var notif = false, lock = false;
      PermissionGate.debugCheck = () async =>
          (notifications: notif, lockScreen: lock);
      PermissionGate.debugAskNotifications = () async => notif = true;
      PermissionGate.debugAskLockScreen = () async => lock = true;
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const PermissionGate(child: Text('THE APP')),
        ),
      );
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('permission-gate')), findsOneWidget);
      expect(find.text('THE APP'), findsNothing);
      expect(find.textContaining('Skip'), findsNothing);
      await t.tap(find.byKey(const ValueKey('perm-allow-notifications')));
      await _frames(t, 2);
      // still waiting for the lock screen one
      expect(find.text('THE APP'), findsNothing);
      expect(find.byKey(const ValueKey('perm-ok')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('perm-allow-notifications')),
        findsNothing,
      );
      await t.tap(find.byKey(const ValueKey('perm-allow-lockscreen')));
      await _frames(t, 2);
      expect(find.text('THE APP'), findsOneWidget);
      await _finish(t);
    });

    testWidgets('turned off later -> asked again when the app comes back', (
      t,
    ) async {
      var notif = true;
      PermissionGate.debugCheck = () async =>
          (notifications: notif, lockScreen: true);
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const PermissionGate(child: Text('THE APP')),
        ),
      );
      await _frames(t, 2);
      expect(find.text('THE APP'), findsOneWidget);
      notif = false;
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('permission-gate')), findsOneWidget);
      await _finish(t);
    });

    test('the app waits behind the gate after login', () {
      final s = File('lib/features/auth/presentation/auth_gate.dart')
          .readAsStringSync();
      expect(s.contains('PermissionGate('), isTrue);
    });
  });

  // ----------------------------------------------------------- removed
  test('no App update and no Test ring any more', () {
    final settings = File(
      'lib/features/settings/presentation/settings_screen.dart',
    ).readAsStringSync();
    expect(settings.contains("'App update'"), isFalse);
    final pages = File('lib/features/settings/presentation/settings_pages.dart')
        .readAsStringSync();
    expect(pages.contains('class UpdateScreen'), isFalse);
    final check = File(
      'lib/features/settings/presentation/call_check_screen.dart',
    ).readAsStringSync();
    expect(check.contains('Test ring'), isFalse);
  });

  test('editor stops the video before the share screen', () {
    final s = File('lib/features/editor/media_editor_screen.dart')
        .readAsStringSync();
    final next = s.substring(s.indexOf('Future<void> _next() async {'));
    final pause = next.indexOf('if (wasPlaying) await c.pause();');
    final push = next.indexOf('CreatePostScreen(items: out');
    expect(pause > 0 && pause < push, isTrue);
  });
}
