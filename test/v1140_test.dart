import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:instantgram/core/l10n.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/finish.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/models/story.dart';
import 'package:instantgram/screens/post/editor_screen.dart';
import 'package:instantgram/screens/settings/app_screens.dart';
import 'package:instantgram/services/overlay_painter.dart';
import 'package:instantgram/widgets/post_actions_sheet.dart';
import 'package:instantgram/widgets/repost_controller.dart';

Post _post({String author = 'other', bool pinned = false}) => Post(
  id: 'p1',
  authorId: author,
  authorUsername: 'name',
  authorPhotoUrl: '',
  type: 'video',
  caption: 'hello',
  createdAt: DateTime(2026),
  videoRef: 'm:video/u/aaaaaaaaaaaaaaaa.mp4',
  pinned: pinned,
);

Future<void> _settle(WidgetTester t, bool Function() done) async {
  for (var i = 0; i < 30 && !done(); i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('forty languages', () {
    test('the list has 40 languages with unique codes', () {
      expect(kLanguages.length, 40);
      expect({for (final l in kLanguages) l.code}.length, 40);
      expect(kLanguages.first.code, 'en');
    });

    test('every language translates the menus, and the new words too', () {
      for (final l in kLanguages.where((l) => l.code != 'en')) {
        final lang = Language.instance..value = l.code;
        for (final w in [
          'Settings',
          'Language',
          'Repost',
          'Analytics',
          'Pin',
          'Audio',
          'Trim',
          'Search',
          'Report',
          'Also share to your moments',
        ]) {
          final out = lang.translate(w);
          expect(out, isNotEmpty, reason: '${l.code} $w');
          if (!{'fil'}.contains(l.code) && w != 'Audio') {
            expect(out, isNot(w), reason: '${l.code} $w stays English');
          }
        }
      }
      Language.instance.value = 'en';
    });

    test('right to left languages are flagged', () {
      for (final c in ['ar', 'ur', 'he', 'fa']) {
        Language.instance.value = c;
        expect(Language.instance.isRtl, isTrue, reason: c);
      }
      Language.instance.value = 'de';
      expect(Language.instance.isRtl, isFalse);
      Language.instance.value = 'en';
    });

    testWidgets('settings lists the languages and can search them', (t) async {
      Language.instance.value = 'en';
      await t.binding.setSurfaceSize(const Size(800, 3000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        LanguageScope(
          language: Language.instance,
          child: MaterialApp(
            theme: AppTheme.light,
            home: const LanguageScreen(),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('language_ja')), findsOneWidget);
      expect(find.byKey(const ValueKey('language_fi')), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('languageSearch')), 'germ');
      await t.pump();
      expect(find.byKey(const ValueKey('language_de')), findsOneWidget);
      expect(find.byKey(const ValueKey('language_ja')), findsNothing);
    });
  });

  group('finish (look, texts, stickers)', () {
    test('a video look and its overlays survive a round trip', () {
      final f = MediaFinish(
        overlays: const [StoryOverlay(text: 'hi', dx: 0.2, dy: 0.7)],
        look: const VideoLook(filter: 2, brightness: 0.1),
      );
      final back = MediaFinish.fromMap(f.toMap())!;
      expect(back.overlays.single.text, 'hi');
      expect(back.look!.filter, 2);
      expect(back.look!.brightness, closeTo(0.1, 1e-6));
    });

    test('nothing chosen means no finish', () {
      expect(const MediaFinish().isEmpty, isTrue);
      expect(const MediaFinish().toMap(), isEmpty);
      expect(MediaFinish.fromMap({'ov': [], 'lk': {'f': 0}}), isNull);
      expect(MediaFinish.fromMap(null), isNull);
    });

    test('a carousel item keeps its finish', () {
      final it = PostItem(
        video: true,
        ref: 'm:video/u/a.mp4',
        finish: const MediaFinish(look: VideoLook(filter: 1)),
      );
      final back = PostItem.fromMap(it.toMap())!;
      expect(back.finish!.look!.filter, 1);
      expect(
        PostItem.fromMap(const PostItem(video: true, ref: 'm:v').toMap())!.finish,
        isNull,
      );
    });
  });

  testWidgets('texts are burned into a photo', (t) async {
    final dir = Directory.systemTemp.createTempSync('bake_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final src = File('${dir.path}/p.jpg');
    final im = img.Image(width: 120, height: 80);
    for (final p in im) {
      p.r = 0;
      p.g = 0;
      p.b = 0;
    }
    src.writeAsBytesSync(img.encodeJpg(im, quality: 95));
    late File out;
    await t.runAsync(() async {
      out = await bakeOverlays(src, const [
        StoryOverlay(text: '★', emoji: true, dx: 0.5, dy: 0.5, scale: 1.5),
        StoryOverlay(text: 'HELLO', dx: 0.5, dy: 0.2, pill: true),
      ]);
    });
    final baked = img.decodeJpg(out.readAsBytesSync())!;
    expect((baked.width, baked.height), (120, 80));
    var lit = 0;
    for (final p in baked) {
      if (p.r > 60 || p.g > 60 || p.b > 60) lit++;
    }
    expect(lit, greaterThan(50), reason: 'the text and sticker were drawn');
  });

  group('the editor', () {
    Future<EditorResult?> open(
      WidgetTester t,
      File file, {
      bool video = false,
    }) async {
      EditorResult? result;
      var closed = false;
      await t.binding.setSurfaceSize(const Size(500, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<EditorResult>(
                      MaterialPageRoute(
                        builder: (_) => EditorScreen(file: file, video: video),
                      ),
                    );
                    closed = true;
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pump(const Duration(milliseconds: 400));
      await _settle(t, () => find.byKey(const ValueKey('tool_text')).evaluate().isNotEmpty);
      // keep a handle for the caller to finish
      _closed = () => closed;
      _result = () => result;
      return null;
    }

    testWidgets('a photo has audio, text, stickers, filters, adjust and crop', (
      t,
    ) async {
      final dir = Directory.systemTemp.createTempSync('editor14');
      addTearDown(() => dir.deleteSync(recursive: true));
      final src = File('${dir.path}/p.jpg');
      final im = img.Image(width: 80, height: 40);
      for (final p in im) {
        p.r = 200;
        p.g = 100;
        p.b = 50;
      }
      src.writeAsBytesSync(img.encodeJpg(im, quality: 95));
      await open(t, src);
      await _settle(t, () => find.byKey(const ValueKey('tool_crop')).evaluate().isNotEmpty);
      for (final k in [
        'tool_audio',
        'tool_text',
        'tool_stickers',
        'tool_filters',
        'tool_adjust',
        'tool_crop',
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      expect(find.byKey(const ValueKey('tool_trim')), findsNothing);
      expect(find.byKey(const ValueKey('tool_mute')), findsNothing);

      // a sticker lands on the picture
      await t.tap(find.byKey(const ValueKey('tool_stickers')));
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
      await t.ensureVisible(find.byKey(const ValueKey('emoji_🔥')));
      await t.tap(find.byKey(const ValueKey('emoji_🔥')));
      await t.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('overlay0')), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('editorDone')));
      await t.pump(const Duration(milliseconds: 300));
      await _settle(t, _closed);
      final r = _result()!;
      expect(r.overlays.single.text, '🔥');
      expect(r.photoFile, isNotNull);
      expect(r.photoFile!.path, isNot(src.path), reason: 'burned into a copy');
    });
  });

  group('post actions', () {
    Future<void> show(WidgetTester t, Post p, {String me = 'me'}) async {
      await t.binding.setSurfaceSize(const Size(500, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        LanguageScope(
          language: Language.instance,
          child: MaterialApp(
            theme: AppTheme.light,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showPostActions(
                    context,
                    p,
                    myUid: me,
                    isReposted: (_) async => false,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pump(const Duration(milliseconds: 500));
    }

    testWidgets('my own post: analytics, pin, share, copy, delete', (t) async {
      await show(t, _post(author: 'me'));
      for (final k in ['actAnalytics', 'actPin', 'actShare', 'actCopy', 'actDelete']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      expect(find.byKey(const ValueKey('actReport')), findsNothing);
      expect(find.byKey(const ValueKey('actRepost')), findsNothing);
    });

    testWidgets('a pinned post offers Unpin', (t) async {
      await show(t, _post(author: 'me', pinned: true));
      expect(find.text('Unpin'), findsOneWidget);
    });

    testWidgets('someone else\'s post: repost and report', (t) async {
      await show(t, _post());
      expect(find.byKey(const ValueKey('actRepost')), findsOneWidget);
      expect(find.byKey(const ValueKey('actReport')), findsOneWidget);
      expect(find.byKey(const ValueKey('actShare')), findsOneWidget);
      expect(find.byKey(const ValueKey('actDelete')), findsNothing);
      expect(find.byKey(const ValueKey('actPin')), findsNothing);
    });
  });

  test('the repost button remembers what you already reposted', () async {
    final c = RepostController(_post(), loader: (_) async => true);
    await Future<void>.delayed(Duration.zero);
    expect(c.reposted, isTrue);
    c.dispose();
  });
}

bool Function() _closed = () => false;
EditorResult? Function() _result = () => null;
