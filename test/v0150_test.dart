// v0.15 tests: bio fonts, moment views + rewatches + search, moment preview,
// highlights, chat preview (no "seen"), app icon.
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/services/app_icon.dart';
import 'package:instantgram/core/services/chat_prefs.dart';
import 'package:instantgram/core/services/content_filter.dart';
import 'package:instantgram/core/services/presence.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/chats/presentation/chat_peek.dart';
import 'package:instantgram/features/chats/presentation/chats_screen.dart';
import 'package:instantgram/features/profile/presentation/edit_profile_screen.dart';
import 'package:instantgram/features/settings/presentation/app_icon_screen.dart';
import 'package:instantgram/features/stories/data/highlight_repository.dart';
import 'package:instantgram/features/stories/data/story_views.dart';
import 'package:instantgram/features/stories/presentation/highlights.dart';
import 'package:instantgram/features/stories/presentation/story_extras.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/models/user_profile.dart';
import 'package:instantgram/shared/widgets/bio_font.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:instantgram/shared/widgets/stickers.dart';

final _t0 = DateTime(2026, 10, 15, 10);

Story _story(
  String id, {
  int minutes = 0,
  bool video = false,
  VideoEdits edits = const VideoEdits(),
}) => Story(
  id: id,
  authorId: 'riya',
  authorUsername: 'riya',
  authorPhotoUrl: '',
  mediaUrl: 'https://x/$id.${video ? 'mp4' : 'jpg'}',
  mediaKey: 'story/riya/$id',
  createdAt: _t0.add(Duration(minutes: minutes)),
  type: video ? Story.video : Story.photo,
  durationMs: video ? 9000 : 0,
  edits: edits,
);

StoryView _view(String uid, int count, int minutes) => StoryView(
  uid: uid,
  username: uid,
  photoUrl: '',
  count: count,
  lastAt: _t0.add(Duration(minutes: minutes)),
);

Highlight _hl(String id, String title, List<Story> items) => Highlight(
  id: id,
  ownerUid: 'riya',
  title: title,
  coverUrl: Highlight.coverOf(items),
  username: 'riya',
  photoUrl: '',
  items: items,
  createdAt: _t0,
);

Message _msg(String id, String from, int min, {DateTime? expireAt}) => Message(
  id: id,
  senderId: from,
  text: 'text $id',
  createdAt: _t0.add(Duration(minutes: min)),
  expireAt: expireAt,
);

Chat _listChat(String other) => Chat.fromMap('me_$other', {
  'members': ['me', other],
  'memberInfo': {
    other: {'username': other, 'photoUrl': ''},
  },
  'lastSenderId': other,
  'lastMessage': 'hi from $other',
  'updatedAt': Timestamp.fromDate(_t0),
});

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark,
  home: Scaffold(body: child),
);

Future<void> _frames(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _finish(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 1));
}

void main() {
  setUpAll(() {
    NetImage.disableCache = true;
    Presence.instance.show.value = false; // no Firestore in tests
    ContentFilter.instance.debugSet(me: 'me');
  });

  // ------------------------------------------------------------ bio fonts
  group('bio fonts', () {
    test('ids, names and styles', () {
      expect(BioFont.ids.length, 23); // v0.16: 12 more
      expect(BioFont.normalize('nope'), '');
      expect(BioFont.normalize(3), '');
      expect(BioFont.label('lobster'), 'Lobster');
      const base = TextStyle(fontSize: 14, height: 1.3);
      expect(BioFont.style('', base), base);
      final s = BioFont.style('lobster', base);
      expect(s.fontFamily, 'BioLobster');
      expect(s.fontSize! > 14, isTrue);
      for (final id in BioFont.ids) {
        expect(id.length <= 20, isTrue, reason: 'rules: max 20 letters');
      }
    });

    test('profile reads bioFont', () {
      final p = UserProfile.fromMap('u', const {
        'username': 'riya',
        'bioFont': 'caveat',
      });
      expect(p.bioFont, 'caveat');
      expect(UserProfile.fromMap('u', const {'username': 'x'}).bioFont, '');
    });

    testWidgets('picker changes the font', (t) async {
      var v = '';
      await t.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, set) =>
                BioFontPicker(value: v, onChanged: (x) => set(() => v = x)),
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('bio-font-lobster')));
      await t.pumpAndSettle();
      expect(v, 'lobster');
      await t.tap(find.byKey(const ValueKey('bio-font-normal')));
      await t.pumpAndSettle();
      expect(v, '');
      await _finish(t);
    });

    testWidgets('edit profile: font picker (v0.16: in the field)', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.5;
      addTearDown(t.view.reset);
      addTearDown(() {
        EditProfileScreen.debugLive = null;
        EditProfileScreen.debugUsernameFree = null;
      });
      final me = UserProfile.fromMap('riya', const {
        'username': 'riya',
        'name': 'Riya',
        'bio': 'hello world',
        'bioFont': 'bebas',
      });
      EditProfileScreen.debugLive = (_) => Stream.value(me);
      EditProfileScreen.debugUsernameFree = (n) async => true;
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: EditProfileScreen(profile: me),
        ),
      );
      await _frames(t);
      // v0.16: the bio field itself shows the fonts (no separate preview)
      await t.scrollUntilVisible(
        find.byKey(const ValueKey('bio-font-caveat')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _frames(t, 3);
      final ctrl = t
          .widgetList<EditableText>(find.byType(EditableText))
          .map((e) => e.controller)
          .whereType<FontRunController>()
          .single;
      expect(ctrl.runs, [const FontRun(0, 11, 'bebas')]);
      ctrl.selection = const TextSelection.collapsed(offset: 3);
      await t.tap(find.byKey(const ValueKey('bio-font-caveat')));
      await _frames(t, 3);
      expect(ctrl.runs, [const FontRun(0, 11, 'caveat')]);
      await _finish(t);
    });
  });

  // ------------------------------------------------- moment views/rewatches
  group('moment views + rewatches', () {
    test('view doc + numbers', () {
      final v = StoryView.fromMap('a', {
        'username': 'amit',
        'count': 4,
        'lastAt': Timestamp.fromDate(_t0),
      });
      expect(v.count, 4);
      expect(v.rewatches, 3);
      expect(v.lastAt, _t0);
      expect(StoryView.fromMap('b', const {}).count, 1);
      expect(StoryView.fromMap('b', const {}).rewatches, 0);

      final list = [
        _view('amit', 4, 1),
        _view('neha', 1, 5),
        _view('ravi', 2, 3),
      ];
      expect(StoryInsights.totals(list), (3, 4));
      expect(StoryInsights.totals(const []), (0, 0));
      expect(StoryInsights.sorted(list).map((v) => v.uid), [
        'neha',
        'ravi',
        'amit',
      ]);
      expect(StoryInsights.sorted(list, mostWatched: true).map((v) => v.uid), [
        'amit',
        'ravi',
        'neha',
      ]);
      expect(StoryInsights.search(list, '@NE').map((v) => v.uid), ['neha']);
      expect(StoryInsights.search(list, '  ').length, 3);
      expect(StoryInsights.watchedLabel(1), 'Watched once');
      expect(StoryInsights.watchedLabel(3), 'Watched 3 times');
    });

    testWidgets('seen-by bar shows people and rewatches', (t) async {
      await t.pumpWidget(
        _app(
          Center(
            child: SeenByBar(
              views: Stream.value([_view('amit', 4, 1), _view('neha', 1, 2)]),
              onTap: () {},
            ),
          ),
        ),
      );
      await _frames(t, 2);
      expect(find.text('2'), findsOneWidget);
      expect(
        t.widget<Text>(find.byKey(const ValueKey('story-rewatches'))).data,
        '3',
      );
      await _finish(t);
    });

    testWidgets('viewer list: totals, search, most watched', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.5;
      addTearDown(t.view.reset);
      final views = [
        _view('amit', 4, 1),
        _view('neha', 1, 5),
        _view('ravi', 2, 3),
      ];
      await t.pumpWidget(_app(StoryViewersSheet(views: Stream.value(views))));
      await _frames(t, 3);
      expect(find.text('3 viewers'), findsOneWidget);
      expect(find.text('4 rewatches'), findsOneWidget);
      expect(find.textContaining('Watched 4 times'), findsOneWidget);
      expect(find.textContaining('Watched once'), findsOneWidget);
      // newest first
      double y(String uid) =>
          t.getTopLeft(find.byKey(ValueKey('viewer-$uid'))).dy;
      expect(y('neha') < y('ravi') && y('ravi') < y('amit'), isTrue);
      // most watched first
      await t.tap(find.byKey(const ValueKey('viewers-sort')));
      await _frames(t, 3);
      expect(y('amit') < y('ravi') && y('ravi') < y('neha'), isTrue);
      // search
      await t.enterText(find.byKey(const ValueKey('viewers-search')), 'ra');
      await _frames(t, 3);
      expect(find.byKey(const ValueKey('viewer-ravi')), findsOneWidget);
      expect(find.byKey(const ValueKey('viewer-amit')), findsNothing);
      await t.enterText(find.byKey(const ValueKey('viewers-search')), 'zzz');
      await _frames(t, 3);
      expect(find.text('No one found'), findsOneWidget);
      await _finish(t);
    });

    testWidgets('no viewers yet', (t) async {
      await t.pumpWidget(
        _app(StoryViewersSheet(views: Stream.value(const []))),
      );
      await _frames(t, 3);
      expect(find.text('No viewers yet'), findsOneWidget);
      expect(find.text('0 viewers'), findsOneWidget);
      await _finish(t);
    });
  });

  // ---------------------------------------------------------- preview
  group('moment preview (long-press)', () {
    testWidgets('small card, steps, open button', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.5;
      addTearDown(t.view.reset);
      var opened = 0;
      final g = StoryGroup('riya', [_story('a'), _story('b', minutes: 5)]);
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showStoryPreview(context, g, onOpen: () => opened++),
              child: const Text('hold'),
            ),
          ),
        ),
      );
      await t.tap(find.text('hold'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('story-preview')), findsOneWidget);
      expect(find.text('riya'), findsOneWidget);
      expect(find.textContaining("won't see you"), findsOneWidget);
      // tap right half = next
      final box = t.getRect(find.byKey(const ValueKey('story-preview')));
      await t.tapAt(Offset(box.right - 20, box.center.dy));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('story-preview-open')));
      await t.pumpAndSettle();
      expect(opened, 1);
      expect(find.byKey(const ValueKey('story-preview')), findsNothing);
      await _finish(t);
    });
  });

  // -------------------------------------------------------- highlights
  group('highlights', () {
    test('title, cover, items', () {
      expect(Highlight.cleanTitle('   '), 'Highlights');
      expect(Highlight.cleanTitle('  Goa   trip '), 'Goa trip');
      expect(Highlight.cleanTitle('x' * 40).length, 30);
      final v = _story('v', video: true);
      final p1 = _story('p1', minutes: 2);
      final p2 = _story('p2', minutes: 1);
      expect(Highlight.coverOf([v, p1, p2]), p1.mediaUrl);
      expect(
        Highlight.coverOf([v, p1, p2], preferred: p2.mediaUrl),
        p2.mediaUrl,
      );
      expect(
        Highlight.coverOf([v, p1], preferred: 'https://other'),
        p1.mediaUrl,
      );
      expect(Highlight.coverOf([v]), '');
      // oldest first, no doubles
      expect(Highlight.cleanItems([p1, v, p2, p1]).map((s) => s.id), [
        'v',
        'p2',
        'p1',
      ]);
      final many = [for (var i = 0; i < 130; i++) _story('s$i', minutes: i)];
      final kept = Highlight.cleanItems(many);
      expect(kept.length, Highlight.maxItems);
      expect(kept.last.id, 's129');
    });

    test('saved copy reads back (video edits too)', () {
      final v = _story(
        'v1',
        video: true,
        edits: const VideoEdits(
          trimStartMs: 1200,
          trimEndMs: 8000,
          muted: true,
        ),
      );
      final p = _story('p1', minutes: 3);
      final map = Highlight.toMap(
        title: '',
        items: [p, v],
        cover: '',
        username: 'riya',
        photoUrl: 'https://x/me.jpg',
      );
      expect(map['title'], 'Highlights');
      expect(map['storyIds'], ['v1', 'p1']);
      expect(map['coverUrl'], p.mediaUrl);
      final h = Highlight.fromMap('h1', 'riya', {
        ...map,
        'createdAt': Timestamp.fromDate(_t0),
      });
      expect(h.items.length, 2);
      final back = h.items.first;
      expect(back.id, 'v1');
      expect(back.isVideo, isTrue);
      expect(back.authorId, 'riya');
      expect(back.authorPhotoUrl, 'https://x/me.jpg');
      expect(back.edits.trimStartMs, 1200);
      expect(back.edits.trimEndMs, 8000);
      expect(back.edits.muted, isTrue);
      expect(back.durationMs, 9000);
      expect(back.createdAt, v.createdAt);
      expect(h.group.authorId, 'riya');
      expect(h.storyIds, ['v1', 'p1']);
      // no mediaKey in the copy (the file is never deleted from a highlight)
      expect((map['items'] as List).first.containsKey('mediaKey'), isFalse);
    });

    testWidgets('my row: New + highlights; tap opens', (t) async {
      Highlight? opened;
      var made = 0;
      final h1 = _hl('h1', 'Goa', [_story('a')]);
      final h2 = _hl('h2', 'Food', [_story('b', video: true)]);
      await t.pumpWidget(
        _app(
          HighlightsRow(
            uid: 'riya',
            isMe: true,
            stream: Stream.value([h1, h2]),
            onOpen: (h) => opened = h,
            onNew: () => made++,
          ),
        ),
      );
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('highlight-new')), findsOneWidget);
      expect(find.text('Goa'), findsOneWidget);
      expect(find.text('Food'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('highlight-new')));
      expect(made, 1);
      await t.tap(find.byKey(const ValueKey('highlight-h2')));
      expect(opened?.id, 'h2');
      await _finish(t);
    });

    testWidgets('others: hidden when there are none', (t) async {
      await t.pumpWidget(
        _app(
          HighlightsRow(
            uid: 'riya',
            isMe: false,
            stream: Stream.value(const []),
          ),
        ),
      );
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('highlights-row')), findsNothing);
      expect(find.byKey(const ValueKey('highlight-new')), findsNothing);
      await _finish(t);
    });

    testWidgets('make a highlight: pick moments, name, cover', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.5;
      addTearDown(t.view.reset);
      String? title;
      List<Story>? items;
      String? cover;
      final moments = [
        _story('old', minutes: -3000), // older than 24 h: still allowed
        _story('vid', minutes: 1, video: true),
        _story('new', minutes: 2),
      ];
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => HighlightEditorScreen(
                    loadMoments: () async => moments,
                    onSave: (a, b, c) async {
                      title = a;
                      items = b;
                      cover = c;
                    },
                  ),
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.text('New highlight'), findsOneWidget);
      expect(find.text('Pick moments'), findsOneWidget);
      final save = find.byKey(const ValueKey('highlight-save'));
      expect(t.widget<TextButton>(save).onPressed, isNull);

      await t.tap(find.byKey(const ValueKey('pick-vid')));
      await t.tap(find.byKey(const ValueKey('pick-old')));
      await t.tap(find.byKey(const ValueKey('pick-new')));
      await t.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget);
      // unpick + pick again
      await t.tap(find.byKey(const ValueKey('pick-vid')));
      await t.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('pick-vid')));
      await t.pumpAndSettle();
      // choose the cover
      await t.tap(find.byKey(const ValueKey('cover-new')));
      await t.enterText(find.byKey(const ValueKey('highlight-name')), 'Trip');
      await t.pumpAndSettle();
      await t.tap(save);
      await t.pumpAndSettle();
      expect(title, 'Trip');
      expect(items!.map((s) => s.id).toSet(), {'vid', 'old', 'new'});
      expect(cover, moments[2].mediaUrl);
      expect(find.text('New highlight'), findsNothing); // closed
      await _finish(t);
    });

    testWidgets('no moments yet', (t) async {
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: HighlightEditorScreen(loadMoments: () async => const []),
        ),
      );
      await t.pumpAndSettle();
      expect(find.textContaining('No moments yet'), findsOneWidget);
      await _finish(t);
    });
  });

  // ----------------------------------------------------- chat preview
  group('chat preview without "seen"', () {
    tearDown(() => ChatPrefs.instance.debugSet(ChatPrefsData.empty));

    test('pick: newest 15, no cleared / expired', () {
      final now = _t0.add(const Duration(hours: 1));
      final all = [
        for (var i = 0; i < 20; i++) _msg('m$i', i.isEven ? 'me' : 'a', i),
        _msg('gone', 'a', 30, expireAt: _t0),
      ];
      final out = ChatPeek.pick(all, me: 'me', now: now);
      expect(out.length, ChatPeek.count);
      expect(out.first.id, 'm19');
      expect(out.any((m) => m.id == 'gone'), isFalse);
      final cleared = ChatPeek.pick(
        all,
        me: 'me',
        now: now,
        clearedAt: _t0.add(const Duration(minutes: 17)),
      );
      expect(cleared.map((m) => m.id), ['m19', 'm18']);
    });

    testWidgets('long-press a chat shows the messages', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.5;
      addTearDown(t.view.reset);
      final asked = <String>[];
      await t.pumpWidget(
        _app(
          ChatsScreen(
            myUid: 'me',
            chats: Stream.value([_listChat('a')]),
            previewMessages: (id) {
              asked.add(id);
              return Stream.value([_msg('x1', 'a', 1), _msg('x2', 'me', 2)]);
            },
          ),
        ),
      );
      await _frames(t, 2);
      await t.longPress(find.byKey(const ValueKey('chat-me_a')));
      await t.pumpAndSettle();
      expect(asked, ['me_a']);
      expect(find.byKey(const ValueKey('chat-peek')), findsOneWidget);
      expect(find.text('text x1'), findsOneWidget);
      expect(find.text('text x2'), findsOneWidget);
      expect(find.textContaining("won't know"), findsOneWidget);
      // menu still there
      expect(find.byKey(const ValueKey('chat-menu-pin')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-menu-delete')), findsOneWidget);
      await _finish(t);
    });
  });

  // ------------------------------------------------------ editor stickers
  group('editor stickers', () {
    test('bigger by default', () {
      expect(StickerPack.defaultSize >= 0.4, isTrue);
      expect(StickerPack.defaultSize < StickerPack.maxSize, isTrue);
    });

    testWidgets('sheet: no "Moving" button, search, pick', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.5;
      addTearDown(t.view.reset);
      String? picked;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  picked = await showModalBottomSheet<String>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => const StickerSheet(),
                  ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await _frames(t, 10);
      expect(find.byKey(const ValueKey('sticker-grid')), findsOneWidget);
      expect(find.text('Moving'), findsNothing);
      expect(find.byKey(const ValueKey('sticker-animated')), findsNothing);
      final q = StickerPack.ids.first.split('_').first;
      await t.enterText(find.byKey(const ValueKey('sticker-search')), q);
      await _frames(t, 3);
      final hits = StickerPack.search(q);
      expect(hits, isNotEmpty);
      await t.tap(find.byKey(ValueKey('sticker-${hits.first}')));
      await _frames(t, 10);
      expect(picked, hits.first);
      await _finish(t);
    });
  });

  // ----------------------------------------------------------- app icon
  group('app icon', () {
    tearDown(() {
      AppIcons.debugGet = null;
      AppIcons.debugSet = null;
    });

    test('ids', () {
      expect(AppIcons.all.length, 6);
      expect(AppIcons.normalize('x'), 'default');
      expect(AppIcons.asset('night'), 'assets/images/app_icon_night.png');
      expect(AppIcons.asset('bad'), 'assets/images/app_icon_default.png');
    });

    testWidgets('pick an icon', (t) async {
      var cur = 'default';
      AppIcons.debugGet = () async => cur;
      AppIcons.debugSet = (id) async => cur = id;
      await t.pumpWidget(
        MaterialApp(theme: AppTheme.dark, home: const AppIconScreen()),
      );
      await t.pumpAndSettle();
      expect(find.text('Classic'), findsOneWidget);
      expect(find.text('Night'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('app-icon-night')));
      await t.pumpAndSettle();
      expect(cur, 'night');
      expect(find.textContaining('Icon changed'), findsOneWidget);
      await _finish(t);
    });
  });
}
