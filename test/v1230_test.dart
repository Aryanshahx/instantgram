import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/fonts.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/app_user.dart';
import 'package:instantgram/models/audience.dart';
import 'package:instantgram/models/story.dart';
import 'package:instantgram/screens/settings/audience_lists_screen.dart';
import 'package:instantgram/screens/story/story_composer.dart';
import 'package:instantgram/services/audience_service.dart';
import 'package:instantgram/services/push_service.dart';
import 'package:instantgram/widgets/audience_sheet.dart';
import 'package:instantgram/widgets/overlay_tools.dart';
import 'package:instantgram/widgets/story_overlays.dart';

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Story _s(String author, {bool spot = false, int min = 0}) => Story(
  id: '$author$min',
  authorId: author,
  username: author,
  photoUrl: '',
  imageRef: '',
  createdAt: DateTime(2026, 10, 8, 12, min),
  spotlight: spot,
);

StoryGroup _g(String author, {bool spot = false, int min = 0}) => StoryGroup(
  authorId: author,
  username: author,
  photoUrl: '',
  stories: [_s(author, spot: spot, min: min)],
);

const _zoe = AppUser(uid: 'u1', username: 'zoe');
const _zack = AppUser(uid: 'u2', username: 'zack');

void main() {
  late MemoryAudiences mem;
  setUp(() {
    mem = MemoryAudiences([
      const AudienceList(id: 'a', name: 'Family', members: ['u1']),
    ]);
    AudienceService.instance
      ..backend = mem
      ..forget();
    AudiencePeople.lookUp = (ids) async => [
      for (final u in [_zoe, _zack])
        if (ids.contains(u.uid)) u,
    ];
    AudiencePeople.search = (q) async => [_zoe, _zack];
  });
  tearDown(() {
    AudienceService.instance
      ..backend = null
      ..forget();
    AudiencePeople.lookUp = null;
    AudiencePeople.search = null;
    PushService.instance.sendBackend = null;
  });

  group('fonts', () {
    test('known ids only; style takes family and weight', () {
      expect(cleanFontId('marker'), 'marker');
      expect(cleanFontId('comic-sans-from-the-future'), '');
      expect(cleanFontId(3), '');
      expect(withAppFont('marker', const TextStyle()).fontFamily, 'Marker');
      final classic = withAppFont('', const TextStyle(fontSize: 9));
      expect(classic.fontFamily, isNull);
      expect(classic.fontWeight, FontWeight.w800);
      expect(classic.fontSize, 9);
      expect(kAppFonts.map((f) => f.id).toSet().length, kAppFonts.length);
    });

    test('a text keeps its font when saved and loaded', () {
      const o = StoryOverlay(text: 'hey', font: 'lobster');
      final back = StoryOverlay.fromMap(o.toMap())!;
      expect(back.font, 'lobster');
      expect(const StoryOverlay(text: 'x').toMap().containsKey('f'), isFalse);
      expect(StoryOverlay.fromMap({'t': 'x', 'f': 'nope'})!.font, '');
      expect(o.copyWith(text: 'b').font, 'lobster');
    });

    testWidgets('the text is drawn in its font', (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: StoryOverlayChip(
            overlay: StoryOverlay(text: 'Hello', font: 'mono'),
            canvasWidth: 300,
          ),
        ),
      );
      final txt = t.widget<Text>(find.text('Hello'));
      expect(txt.style!.fontFamily, 'SpaceMono');
    });

    testWidgets('the text sheet offers the fonts and returns the choice', (
      t,
    ) async {
      StoryOverlay? got;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => Scaffold(
              body: TextButton(
                onPressed: () async => got = await showOverlayTextSheet(
                  c,
                  const StoryOverlay(text: 'hi'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await _settle(t);
      expect(find.byKey(const ValueKey('fontRow')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('font_bebas')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('storyTextDone')));
      await _settle(t);
      expect(got!.font, 'bebas');
      expect(got!.text, 'hi');
    });
  });

  group('spotlight', () {
    test('me first, then spotlights, then newest', () {
      final l = [
        _g('old', min: 1),
        _g('new', min: 9),
        _g('star', spot: true, min: 0),
        _g('me', min: 0),
      ]..sort((a, b) => compareStoryGroups(a, b, 'me'));
      expect(l.map((g) => g.authorId), ['me', 'star', 'new', 'old']);
      expect(_g('star', spot: true).spotlight, isTrue);
    });
  });

  group('audience lists', () {
    test('names, who sees it', () {
      expect(AudienceList.cleanName('   '), 'List');
      expect(AudienceList.cleanName('  Close   friends '), 'Close friends');
      expect(AudienceList.cleanName('x' * 40).length, 30);
      const l = AudienceList(id: 'a', name: 'F', members: ['b', 'me', 'c']);
      expect(l.audienceWith('me'), ['me', 'b', 'c']);
      expect(const StoryAudience.everyone().label, 'Everyone');
      expect(const StoryAudience.only(l).label, 'F');
      final back = AudienceList.fromMap('z', l.toMap());
      expect(back.members, ['b', 'me', 'c']);
      expect(
        Story(
          id: 'x',
          authorId: 'a',
          username: '',
          photoUrl: '',
          imageRef: '',
          createdAt: DateTime(2026),
          limited: true,
        ).collection,
        kPrivateStories,
      );
    });

    test('service keeps lists sorted and forgets on delete', () async {
      final s = AudienceService.instance;
      final saved = await s.save(const AudienceList(id: '', name: 'besties'));
      expect(saved.id, isNotEmpty);
      expect((await s.lists()).map((l) => l.name), ['besties', 'Family']);
      await s.delete(saved.id);
      expect((await s.lists()).map((l) => l.name), ['Family']);
      expect(mem.all.length, 1);
    });

    testWidgets('picker: everyone or a list', (t) async {
      StoryAudience? got;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => Scaffold(
              body: TextButton(
                onPressed: () async => got = await pickStoryAudience(
                  c,
                  const StoryAudience.everyone(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await _settle(t);
      expect(find.text('Family'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('aud_a')));
      await _settle(t);
      expect(got!.list!.id, 'a');
    });

    testWidgets('editor: name, add by search, remove, save', (t) async {
      AudienceList? saved;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => Scaffold(
              body: TextButton(
                onPressed: () async =>
                    saved = await editAudienceList(c, mem.all.first),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await _settle(t);
      expect(find.byKey(const ValueKey('audMember_u1')), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('audName')), 'Close friends');
      await t.enterText(find.byKey(const ValueKey('audSearch')), 'za');
      await t.pump(const Duration(milliseconds: 400));
      await _settle(t);
      await t.tap(find.byKey(const ValueKey('audFound_u2')));
      await _settle(t);
      expect(find.byKey(const ValueKey('audMember_u2')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('audRemove_u1')));
      await _settle(t);
      await t.tap(find.byKey(const ValueKey('audSave')));
      await _settle(t);
      expect(saved!.name, 'Close friends');
      expect(saved!.members, ['u2']);
      expect(mem.all.single.members, ['u2']);
    });
  });

  group('composer', () {
    testWidgets('audience and spotlight tools show what is chosen', (t) async {
      final png = File('${Directory.systemTemp.path}/v1230_pixel.png')
        ..writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
          ),
        );
      await t.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: StoryComposerScreen(image: png),
        ),
      );
      await t.pump();
      expect(find.byKey(const ValueKey('storyAudienceBadge')), findsNothing);
      await t.tap(find.byKey(const ValueKey('storyAudience')));
      await _settle(t);
      await t.tap(find.byKey(const ValueKey('aud_a')));
      await _settle(t);
      expect(find.text('Only Family'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('storySpotlight')));
      await _settle(t);
      expect(find.byKey(const ValueKey('storySpotlightBadge')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('storyAudience')));
      await _settle(t);
      await t.tap(find.byKey(const ValueKey('aud_everyone')));
      await _settle(t);
      expect(find.byKey(const ValueKey('storyAudienceBadge')), findsNothing);
      await t.pump(const Duration(seconds: 4)); // toast away
    });
  });

  test('a list-only view alert names its collection', () async {
    final sent = <Map<String, dynamic>>[];
    PushService.instance.sendBackend = (b) async => sent.add(b);
    PushService.instance.storyView('s', limited: true);
    PushService.instance.storyView('t');
    await Future<void>.delayed(Duration.zero);
    expect(sent, [
      {'kind': 'storyView', 'storyId': 's', 'col': 'p'},
      {'kind': 'storyView', 'storyId': 't'},
    ]);
  });
}
