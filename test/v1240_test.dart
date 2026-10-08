import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/audience.dart';
import 'package:instantgram/models/highlight.dart';
import 'package:instantgram/models/story.dart';
import 'package:instantgram/screens/story/story_composer.dart';
import 'package:instantgram/services/audience_service.dart';
import 'package:instantgram/services/highlight_service.dart';
import 'package:instantgram/widgets/audience_sheet.dart';
import 'package:instantgram/widgets/highlights.dart';

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Story _story(String id, {int day = 1, bool video = false}) => Story(
  id: id,
  authorId: 'me',
  username: 'me',
  photoUrl: '',
  imageRef: video ? '' : 'i:$id',
  videoRef: video ? 'v:$id' : '',
  thumbRef: video ? 't:$id' : '',
  createdAt: DateTime(2026, 10, day),
);

HighlightItem _own(String id) => HighlightItem(
  id: id,
  imageRef: 'i:$id',
  createdAt: DateTime(2026, 10, 1),
  own: true,
);

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark,
  home: Scaffold(body: child),
);

void main() {
  late MemoryHighlights mem;
  late List<String> deleted;
  setUp(() {
    mem = MemoryHighlights();
    deleted = [];
    HighlightService.instance
      ..backend = mem
      ..deleteFiles = (r) async {
        deleted.addAll(r);
      }
      ..forget();
    AudienceService.instance
      ..backend = MemoryAudiences([])
      ..forget();
  });
  tearDown(() {
    HighlightService.instance
      ..backend = null
      ..deleteFiles = null
      ..forget();
    AudienceService.instance
      ..backend = null
      ..forget();
    debugArchive = null;
  });

  group('model', () {
    test('item round trip; copies keep their story files, own ones not', () {
      final s = _story('s1', video: true);
      final item = HighlightItem.fromStory(s, id: 'x');
      final back = HighlightItem.fromMap(item.toMap())!;
      expect(back.videoRef, 'v:s1');
      expect(back.thumbRef, 't:s1');
      expect(back.storyId, 's1');
      expect(back.own, isFalse);
      expect(
        back.toStory('me', 'me', '').shared,
        isTrue,
      ); // never deletes files
      expect(_own('o').toStory('me', 'me', '').shared, isFalse);
      expect(back.refs, {'v:s1', 't:s1'});
      expect(HighlightItem.fromMap('junk'), isNull);
    });

    test('title cleaned; cover = newest unless chosen', () {
      expect(Highlight.cleanTitle('   '), 'Highlights');
      expect(Highlight.cleanTitle('  a   b '), 'a b');
      expect(Highlight.cleanTitle('x' * 40).length, 20);
      final h = Highlight(id: 'h', title: 't', items: [_own('a'), _own('b')]);
      expect(h.cover, 'i:b');
      expect(h.copyWith(coverRef: 'i:a').cover, 'i:a');
      final m = Highlight.fromMap('h', h.toMap());
      expect(m.items.length, 2);
      expect(m.toGroup('me', 'me', '').stories.map((s) => s.id), ['a', 'b']);
    });

    test('audience label for a highlight', () {
      const h = Highlight(id: 'h', title: 'Goa');
      const a = StoryAudience.highlightOnly(h);
      expect(a.isEveryone, isFalse);
      expect(a.label, 'highlight "Goa"');
      expect(a.list, isNull);
    });
  });

  group('service', () {
    test('create empty, add a moment once', () async {
      final s = HighlightService.instance;
      var h = await s.create('Trips');
      expect(h.items, isEmpty);
      h = await s.addStory(h, _story('s1'));
      h = await s.addStory(h, _story('s1'));
      expect(h.items.length, 1);
      expect((await s.of('me')).single.items.single.storyId, 's1');
    });

    test('removing a copied moment never deletes files', () async {
      final s = HighlightService.instance;
      var h = await s.create('A');
      h = await s.addStory(h, _story('s1'));
      h = await s.remove(h, h.items.single.id);
      expect(h.items, isEmpty);
      expect(deleted, isEmpty);
    });

    test('own files go only when no other highlight uses them', () async {
      final s = HighlightService.instance;
      var a = await s.create('A', items: [_own('o1'), _own('o2')]);
      await s.create('B', items: [_own('o2')]);
      a = await s.remove(a, 'o1');
      expect(deleted, ['i:o1']);
      await s.delete(a); // o2 is still in B
      expect(deleted, ['i:o1']);
      expect((await s.of('me')).map((h) => h.title), ['B']);
    });

    test('refsInUse keeps a deleted moment\'s files', () async {
      final s = HighlightService.instance;
      final h = await s.create('A');
      await s.addStory(h, _story('s1', video: true));
      expect(await s.refsInUse(), containsAll(['v:s1', 't:s1']));
    });

    test('limit on highlights', () async {
      mem.data['me'] = [
        for (var i = 0; i < Highlight.maxHighlights; i++)
          Highlight(id: 'h$i', title: '$i'),
      ];
      expect(
        () => HighlightService.instance.create('one more'),
        throwsStateError,
      );
    });
  });

  group('ui', () {
    testWidgets('my row: New + highlights; others with none: hidden', (
      t,
    ) async {
      mem.data['me'] = [
        Highlight(id: 'h1', title: 'Goa', items: [_own('a')]),
      ];
      await t.pumpWidget(
        _app(
          const HighlightsRow(
            uid: 'me',
            username: 'me',
            photoUrl: '',
            isMe: true,
          ),
        ),
      );
      await _settle(t);
      expect(find.byKey(const ValueKey('hlNew')), findsOneWidget);
      expect(find.text('Goa'), findsOneWidget);

      await t.pumpWidget(
        _app(
          const HighlightsRow(
            uid: 'zoe',
            username: 'zoe',
            photoUrl: '',
            isMe: false,
          ),
        ),
      );
      await _settle(t);
      expect(find.byKey(const ValueKey('highlightsRow')), findsNothing);
    });

    testWidgets('New: name, pick moments, created oldest first', (t) async {
      await t.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      debugArchive = () async => [_story('new', day: 5), _story('old', day: 2)];
      await t.pumpWidget(
        _app(
          const HighlightsRow(
            uid: 'me',
            username: 'me',
            photoUrl: '',
            isMe: true,
          ),
        ),
      );
      await _settle(t);
      await t.tap(find.byKey(const ValueKey('hlNew')));
      await _settle(t);
      await t.enterText(find.byKey(const ValueKey('hlTitle')), 'Summer');
      await t.tap(find.byKey(const ValueKey('hlTitleOk')));
      await _settle(t);
      expect(find.text('Create empty'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('arch_new')));
      await t.tap(find.byKey(const ValueKey('arch_old')));
      await t.pump();
      expect(find.text('Create (2)'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('hlCreate')));
      await _settle(t);
      final h = mem.data['me']!.single;
      expect(h.title, 'Summer');
      expect(h.items.map((i) => i.storyId), ['old', 'new']);
      expect(find.text('Summer'), findsOneWidget); // back on the row
    });

    testWidgets('empty highlight can be created', (t) async {
      debugArchive = () async => [];
      await t.pumpWidget(_app(const NewHighlightScreen(title: 'Later')));
      await _settle(t);
      await t.tap(find.byKey(const ValueKey('hlCreate')));
      await _settle(t);
      expect(mem.data['me']!.single.items, isEmpty);
    });

    testWidgets('long-press my highlight: rename', (t) async {
      mem.data['me'] = [const Highlight(id: 'h1', title: 'Old')];
      await t.pumpWidget(
        _app(
          const HighlightsRow(
            uid: 'me',
            username: 'me',
            photoUrl: '',
            isMe: true,
          ),
        ),
      );
      await _settle(t);
      await t.longPress(find.byKey(const ValueKey('hl_h1')));
      await _settle(t);
      await t.tap(find.byKey(const ValueKey('hlRename')));
      await _settle(t);
      await t.enterText(find.byKey(const ValueKey('hlTitle')), 'New name');
      await t.tap(find.byKey(const ValueKey('hlTitleOk')));
      await _settle(t);
      expect(mem.data['me']!.single.title, 'New name');
      expect(find.text('New name'), findsOneWidget);
    });

    testWidgets('audience sheet: share only to a highlight', (t) async {
      mem.data['me'] = [const Highlight(id: 'h1', title: 'Goa')];
      StoryAudience? got;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (ctx) => TextButton(
              onPressed: () async => got = await pickStoryAudience(
                ctx,
                const StoryAudience.everyone(),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await _settle(t);
      expect(find.text('ONLY A HIGHLIGHT'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('audHl_h1')));
      await _settle(t);
      expect(got?.highlight?.id, 'h1');
    });

    testWidgets('composer badge says only the highlight', (t) async {
      await t.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      mem.data['me'] = [const Highlight(id: 'h1', title: 'Goa')];
      final dir = Directory.systemTemp.createTempSync();
      final png = File('${dir.path}/a.png')
        ..writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
          ),
        );
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: StoryComposerScreen(image: png),
        ),
      );
      await _settle(t);
      await t.tap(find.byKey(const ValueKey('storyAudience')));
      await _settle(t);
      await t.tap(find.byKey(const ValueKey('audHl_h1')));
      await _settle(t);
      expect(find.text('Only highlight "Goa"'), findsOneWidget);
    });
  });
}
