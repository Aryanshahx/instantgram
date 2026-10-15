// v0.16 tests: many bio fonts, moment viewer list fix (shared live list),
// moment likes, music on moments, profile-only posts, highlight-only
// moments, chat fonts, text fonts, more stickers, custom app icon.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:instantgram/core/services/app_icon.dart';
import 'package:instantgram/core/services/app_settings.dart';
import 'package:instantgram/core/services/content_filter.dart';
import 'package:instantgram/core/services/music_player.dart';
import 'package:instantgram/core/services/presence.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/chats/presentation/message_widgets.dart';
import 'package:instantgram/features/notifications/presentation/notifications_screen.dart';
import 'package:instantgram/features/post/data/post_repository.dart';
import 'package:instantgram/features/post/data/upload_queue.dart';
import 'package:instantgram/features/post/presentation/create_post_screen.dart';
import 'package:instantgram/features/settings/presentation/app_icon_screen.dart';
import 'package:instantgram/features/stories/data/highlight_repository.dart';
import 'package:instantgram/features/stories/data/story_views.dart';
import 'package:instantgram/features/stories/presentation/story_viewer_screen.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/models/user_profile.dart';
import 'package:instantgram/shared/widgets/bio_font.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:instantgram/shared/widgets/stickers.dart';
import 'package:instantgram/shared/widgets/video_extras.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _t0 = DateTime(2026, 10, 15, 10);

Story _story(String id, {String author = 'riya', String audio = ''}) => Story(
  id: id,
  authorId: author,
  authorUsername: author,
  authorPhotoUrl: '',
  mediaUrl: 'https://x/$id.jpg',
  mediaKey: 'story/$author/$id',
  createdAt: _t0,
  audioUrl: audio,
  audioName: audio.isEmpty ? '' : 'Song',
);

StoryView _view(String uid, int count, {bool liked = false}) => StoryView(
  uid: uid,
  username: uid,
  photoUrl: '',
  count: count,
  lastAt: _t0,
  liked: liked,
);

Post _post(String id, {bool profileOnly = false, String author = 'amit'}) =>
    Post.fromMap(id, {
      'authorId': author,
      'authorUsername': author,
      'type': 'photo',
      'mediaUrl': 'https://x/$id.jpg',
      if (profileOnly) 'profileOnly': true,
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
    MusicPlayer.disabled = true;
    Presence.instance.show.value = false;
    ContentFilter.instance.debugSet(me: 'me');
  });

  // ------------------------------------------------------- many bio fonts
  group('many fonts in the bio', () {
    test('23 fonts, all short ids, all in pubspec + assets', () {
      expect(BioFont.ids.length, 23);
      final pub = File('pubspec.yaml').readAsStringSync();
      for (final id in BioFont.ids) {
        expect(id.length <= 20, isTrue);
        final fam = BioFont.all[id]!.$2;
        if (fam.isEmpty || fam == 'Pacifico') continue;
        expect(pub.contains('family: $fam'), isTrue, reason: fam);
        final file = 'assets/fonts/Bio-${fam.substring(3)}.ttf';
        expect(File(file).existsSync(), isTrue, reason: file);
      }
      expect(BioFont.family('', 'App'), 'App');
      expect(BioFont.family('neon', 'App'), 'BioNeon');
      expect(BioFont.factor('bad'), 1);
    });

    test('runs: parse, chars, back, spans, trim', () {
      final runs = FontRuns.parse([
        {'s': 0, 'e': 5, 'f': 'lobster'},
        {'s': 6, 'e': 99, 'f': 'neon'},
        {'s': 2, 'e': 2, 'f': 'neon'}, // empty: skipped
        {'s': 1, 'e': 3, 'f': 'nope'}, // unknown font: skipped
        'bad',
      ], 11);
      expect(runs, const [FontRun(0, 5, 'lobster'), FontRun(6, 11, 'neon')]);
      final chars = FontRuns.toChars(11, runs);
      expect(chars[5], '');
      expect(FontRuns.fromChars(chars), runs);
      final spans = FontRuns.spans(
        'hello world',
        runs,
        const TextStyle(fontSize: 10),
      );
      expect(spans.map((s) => s.text).join(), 'hello world');
      expect(spans.length, 3);
      expect(spans.first.style!.fontFamily, 'BioLobster');
      expect(spans[1].style!.fontFamily, isNull);
      expect(spans.last.style!.fontFamily, 'BioNeon');
      final (t, r) = FontRuns.trimmed('  hi you ', const [
        FontRun(0, 4, 'neon'),
        FontRun(5, 8, 'comic'),
      ]);
      expect(t, 'hi you');
      expect(r, const [FontRun(0, 2, 'neon'), FontRun(3, 6, 'comic')]);
      expect(
        FontRuns.parse(
          List.filled(80, {'s': 0, 'e': 1, 'f': 'neon'}),
          1,
        ).length,
        FontRuns.maxRuns,
      );
    });

    test('an emoji is never cut in two', () {
      const text = 'a😀b';
      final chars = ['neon', 'neon', 'comic', 'comic'];
      final runs = FontRuns.fromChars(chars, text);
      expect(runs.first, const FontRun(0, 3, 'neon'));
      final spans = FontRuns.spans(text, runs, const TextStyle());
      expect(spans.map((s) => s.text).toList(), ['a😀', 'b']);
    });

    test('controller: select words + font, line font, typing', () {
      final c = FontRunController(text: 'hello world\nsecond line');
      expect(c.runs, isEmpty);
      // select "world"
      c.selection = const TextSelection(baseOffset: 6, extentOffset: 11);
      c.applyFont('lobster');
      expect(c.runs, const [FontRun(6, 11, 'lobster')]);
      // cursor on line 2, no selection = the whole line
      c.selection = const TextSelection.collapsed(offset: 15);
      c.applyFont('neon');
      expect(c.runs, const [
        FontRun(6, 11, 'lobster'),
        FontRun(12, 23, 'neon'),
      ]);
      expect(c.fontAtCursor, 'neon');
      // typing at the end takes the font of the letter before
      c.value = const TextEditingValue(
        text: 'hello world\nsecond line!',
        selection: TextSelection.collapsed(offset: 24),
      );
      expect(c.runs.last, const FontRun(12, 24, 'neon'));
      // deleting "hello " moves the parts
      c.value = const TextEditingValue(
        text: 'world\nsecond line!',
        selection: TextSelection.collapsed(offset: 0),
      );
      expect(c.runs, const [FontRun(0, 5, 'lobster'), FontRun(6, 18, 'neon')]);
      // an empty new line: the font chosen first is used for typing
      c.value = const TextEditingValue(
        text: 'world\nsecond line!\n',
        selection: TextSelection.collapsed(offset: 19),
      );
      c.applyFont('comic');
      expect(c.fontAtCursor, 'comic');
      c.value = const TextEditingValue(
        text: 'world\nsecond line!\nok',
        selection: TextSelection.collapsed(offset: 21),
      );
      expect(c.runs.last, const FontRun(19, 21, 'comic'));
      c.dispose();
    });

    test('profile: bioFonts, or the old one font', () {
      final p = UserProfile.fromMap('u', const {
        'username': 'riya',
        'bio': 'hi there',
        'bioFonts': [
          {'s': 0, 'e': 2, 'f': 'neon'},
        ],
      });
      expect(p.bioFontRuns, const [FontRun(0, 2, 'neon')]);
      final old = UserProfile.fromMap('u', const {
        'username': 'riya',
        'bio': 'hi there',
        'bioFont': 'bebas',
      });
      expect(old.bioFontRuns, const [FontRun(0, 8, 'bebas')]);
      expect(
        UserProfile.fromMap('u', const {'username': 'x'}).bioFontRuns,
        isEmpty,
      );
    });

    testWidgets('picker keys for chat / editor', (t) async {
      String? v;
      await t.pumpWidget(
        _app(
          BioFontPicker(
            value: '',
            small: true,
            keyPrefix: 'chat-font',
            onChanged: (x) => v = x,
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('chat-font-pixel')));
      await t.pump();
      expect(v, 'pixel');
      await _finish(t);
    });
  });

  // ---------------------------------------------- moment viewer list fix
  group('moment viewers (fix)', () {
    test('LatestValue: a late listener gets the newest list at once', () async {
      final src = StreamController<List<StoryView>>.broadcast();
      final hub = LatestValue(src.stream);
      final first = <int>[];
      final sub1 = hub.stream.listen((l) => first.add(l.length));
      src.add([_view('a', 1)]);
      await Future<void>.delayed(Duration.zero);
      expect(first, [1]);
      // a second listener (the viewer list) joins after the event
      final late = <int>[];
      final sub2 = hub.stream.listen((l) => late.add(l.length));
      await Future<void>.delayed(Duration.zero);
      expect(late, [1]);
      src.add([_view('a', 2), _view('b', 1)]);
      await Future<void>.delayed(Duration.zero);
      expect(first, [1, 2]);
      expect(late, [1, 2]);
      expect(hub.value!.length, 2);
      await sub1.cancel();
      await sub2.cancel();
      hub.dispose();
      await src.close();
    });

    testWidgets('own moment: bar + list share ONE live list; search works', (
      t,
    ) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.5;
      addTearDown(t.view.reset);
      SharedPreferences.setMockInitialValues({});
      final src = StreamController<List<StoryView>>.broadcast();
      var calls = 0;
      StoryViewerScreen.debugMe = 'riya';
      StoryViewerScreen.debugViews = (id) {
        calls++;
        return src.stream;
      };
      addTearDown(() {
        StoryViewerScreen.debugMe = null;
        StoryViewerScreen.debugViews = null;
      });
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: StoryViewerScreen(
            groups: [
              StoryGroup('riya', [_story('s1')]),
            ],
          ),
        ),
      );
      await _frames(t, 3);
      // the broadcast list sends its first data BEFORE the sheet opens
      src.add([
        _view('amit', 3, liked: true),
        _view('neha', 1),
        _view('ravi', 2),
      ]);
      await _frames(t, 3);
      expect(find.byKey(const ValueKey('story-rewatches')), findsOneWidget);
      expect(find.byKey(const ValueKey('story-likes')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('story-seen-by')));
      await _frames(t, 10);
      // before v0.16 this spun forever
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('3 viewers'), findsOneWidget);
      expect(find.text('3 rewatches'), findsOneWidget);
      expect(find.text('1 like'), findsOneWidget);
      expect(find.byKey(const ValueKey('viewer-liked-amit')), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('viewers-search')), 'ne');
      await _frames(t, 3);
      expect(find.byKey(const ValueKey('viewer-neha')), findsOneWidget);
      expect(find.byKey(const ValueKey('viewer-amit')), findsNothing);
      await t.enterText(find.byKey(const ValueKey('viewers-search')), '');
      await t.tap(find.byKey(const ValueKey('viewers-liked')));
      await _frames(t, 3);
      expect(find.byKey(const ValueKey('viewer-amit')), findsOneWidget);
      expect(find.byKey(const ValueKey('viewer-neha')), findsNothing);
      expect(calls, 1, reason: 'one Firestore listener for bar + list');
      await _finish(t);
      await src.close();
    });
  });

  // ------------------------------------------------------- moment likes
  group('moment likes', () {
    test('view doc liked + count', () {
      expect(StoryView.fromMap('a', const {'liked': true}).liked, isTrue);
      expect(StoryView.fromMap('a', const {}).liked, isFalse);
      expect(
        StoryInsights.likes([
          _view('a', 1, liked: true),
          _view('b', 2),
          _view('c', 1, liked: true),
        ]),
        2,
      );
    });

    testWidgets('heart on someone else\'s moment (after the view is saved)', (
      t,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final log = <String>[];
      final saved = Completer<void>();
      StoryViewerScreen.debugMe = 'me';
      StoryViewerScreen.debugRecordView = (st) {
        log.add('view ${st.id}');
        return saved.future;
      };
      StoryViewerScreen.debugMyLike = (id) async => false;
      StoryViewerScreen.debugLike = (st, on) async => log.add('like $on');
      addTearDown(() {
        StoryViewerScreen.debugMe = null;
        StoryViewerScreen.debugRecordView = null;
        StoryViewerScreen.debugMyLike = null;
        StoryViewerScreen.debugLike = null;
      });
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: StoryViewerScreen(
            groups: [
              StoryGroup('riya', [_story('s9')]),
            ],
          ),
        ),
      );
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('story-seen-by')), findsNothing);
      expect(find.byKey(const ValueKey('story-unliked')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('story-like')));
      await _frames(t, 3);
      expect(find.byKey(const ValueKey('story-liked')), findsOneWidget);
      // the like waits for the view doc
      expect(log, ['view s9']);
      saved.complete();
      await _frames(t, 2);
      expect(log, ['view s9', 'like true']);
      await t.tap(find.byKey(const ValueKey('story-like')));
      await _frames(t, 3);
      expect(log.last, 'like false');
      expect(find.byKey(const ValueKey('story-unliked')), findsOneWidget);
      await _finish(t);
      expect(AppSettings.instance.isSeen('s9'), isTrue);
    });

    testWidgets('a failed like goes back', (t) async {
      SharedPreferences.setMockInitialValues({});
      StoryViewerScreen.debugMe = 'me';
      StoryViewerScreen.debugRecordView = (st) async {};
      StoryViewerScreen.debugMyLike = (id) async => false;
      StoryViewerScreen.debugLike = (st, on) async =>
          throw StateError('denied');
      addTearDown(() {
        StoryViewerScreen.debugMe = null;
        StoryViewerScreen.debugRecordView = null;
        StoryViewerScreen.debugMyLike = null;
        StoryViewerScreen.debugLike = null;
      });
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: StoryViewerScreen(
            groups: [
              StoryGroup('riya', [_story('s10')]),
            ],
          ),
        ),
      );
      await _frames(t, 2);
      await t.tap(find.byKey(const ValueKey('story-like')));
      await _frames(t, 4);
      expect(find.byKey(const ValueKey('story-unliked')), findsOneWidget);
      expect(find.text("Couldn't save your like"), findsOneWidget);
      await _finish(t);
    });

    testWidgets('highlights: no heart, no bar', (t) async {
      StoryViewerScreen.debugMe = 'me';
      addTearDown(() => StoryViewerScreen.debugMe = null);
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: StoryViewerScreen(
            recordViews: false,
            groups: [
              StoryGroup('riya', [_story('s11')]),
            ],
          ),
        ),
      );
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('story-like')), findsNothing);
      expect(find.byKey(const ValueKey('story-seen-by')), findsNothing);
      await _finish(t);
    });

    test('notification text + push text', () {
      final n = AppNotification(
        id: 'n',
        type: AppNotification.momentLike,
        fromUid: 'a',
        fromUsername: 'amit',
        fromPhotoUrl: '',
        postId: '',
        postThumb: '',
        text: '',
        read: false,
        createdAt: _t0,
      );
      expect(notificationText(n), 'liked your moment.');
      final js = File('backend/api/activity-push.js').readAsStringSync();
      expect(js.contains("moment_like: 'likes'"), isTrue);
      expect(js.contains('liked your moment'), isTrue);
      final rules = File('firestore.rules').readAsStringSync();
      expect(rules.contains("'moment_like'"), isTrue);
    });
  });

  // ---------------------------------------------------- music on moments
  group('music on moments', () {
    test('story audio fields + highlight copy keeps the music', () {
      final st = Story.fromMap('s', {
        'authorId': 'riya',
        'mediaUrl': 'https://x/s.jpg',
        'audioUrl': 'https://x/song.m4a',
        'audioKey': 'audio/riya/1',
        'audioName': 'My song',
        'createdAt': Timestamp.fromDate(_t0),
      });
      expect(st.hasMusic, isTrue);
      expect(st.audioName, 'My song');
      final item = st.toHighlightItem();
      expect(item['audioUrl'], 'https://x/song.m4a');
      expect(item['audioName'], 'My song');
      expect(_story('x').toHighlightItem().containsKey('audioUrl'), isFalse);
      expect(Story.musicPhotoMs, 15000);
    });

    testWidgets('photo moment with music: chip + 15 s', (t) async {
      SharedPreferences.setMockInitialValues({});
      StoryViewerScreen.debugMe = 'riya';
      StoryViewerScreen.debugViews = (_) => const Stream.empty();
      addTearDown(() {
        StoryViewerScreen.debugMe = null;
        StoryViewerScreen.debugViews = null;
      });
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: StoryViewerScreen(
            groups: [
              StoryGroup('riya', [_story('m1', audio: 'https://x/song.m4a')]),
            ],
          ),
        ),
      );
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('story-music')), findsOneWidget);
      expect(find.text('Song'), findsOneWidget);
      // after 6 s it is still on screen (a plain photo goes after 5 s)
      await t.pump(const Duration(seconds: 6));
      expect(find.byKey(const ValueKey('story-music')), findsOneWidget);
      await _finish(t);
    });
  });

  // ------------------------------------------------- profile-only posts
  group('profile only', () {
    test('post field + feeds leave it out', () async {
      final a = _post('a');
      final b = _post('b', profileOnly: true);
      expect(b.profileOnly, isTrue);
      final f = ContentFilter.instance;
      expect(f.canSee(b), isTrue, reason: 'still on the profile');
      expect(f.canSeeInFeeds(b), isFalse);
      expect(f.canSeeInFeeds(a), isTrue);
      final out = await f.feedPosts(Stream.value([a, b])).first;
      expect(out.map((p) => p.id), ['a']);
      final all = await f.visiblePosts(Stream.value([a, b])).first;
      expect(all.length, 2);
    });

    test('options survive an app restart (upload queue)', () {
      final task = UploadTask(
        id: 't1',
        kind: UploadTask.moment,
        items: [QueuedMedia(path: '/x/a.jpg', isVideo: false)],
        options: const PostOptions(
          profileOnly: true,
          highlightId: 'h1',
          highlightTitle: 'Goa',
        ),
        audioPath: '/x/song.m4a',
        audioName: 'Song',
      );
      expect(task.label, contains('highlight'));
      final back = UploadTask.fromJson(task.toJson())!;
      expect(back.options.profileOnly, isTrue);
      expect(back.options.highlightOnly, isTrue);
      expect(back.options.highlightId, 'h1');
      expect(back.options.highlightTitle, 'Goa');
      expect(back.audioPath, '/x/song.m4a');
      expect(const PostOptions().highlightOnly, isFalse);
    });

    test('rules allow the new fields', () {
      final r = File('firestore.rules').readAsStringSync();
      expect(r.contains("d.profileOnly is bool"), isTrue);
      expect(r.contains("'bioFonts'"), isTrue);
      expect(r.contains("'liked', 'likedAt'"), isTrue);
      expect(r.contains("'font'"), isTrue);
    });
  });

  // --------------------------------------------- share screen (v0.16)
  group('share screen', () {
    late File photo;
    setUpAll(() {
      final dir = Directory.systemTemp.createTempSync('ig16');
      photo = File('${dir.path}/p.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 4, height: 4)));
    });
    tearDown(() => CreatePostScreen.debugHighlights = null);

    testWidgets('post: "Only on your profile" switch', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.5;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: CreatePostScreen(
            items: [EditedMedia(file: photo, isVideo: false, aspectRatio: 1)],
            mode: ComposeMode.photo,
          ),
        ),
      );
      await _frames(t, 3);
      await t.scrollUntilVisible(
        find.text('Only on your profile'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Not shown in feeds, Explore or Clips'), findsOneWidget);
      expect(find.byKey(const ValueKey('share-to-highlight')), findsNothing);
      await _finish(t);
    });

    testWidgets('moment: share to a highlight only', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.5;
      addTearDown(t.view.reset);
      CreatePostScreen.debugHighlights = () => Stream.value([
        Highlight(
          id: 'h1',
          ownerUid: 'me',
          title: 'Goa',
          coverUrl: '',
          username: 'me',
          photoUrl: '',
          items: [_story('old', author: 'me')],
          createdAt: _t0,
        ),
      ]);
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: CreatePostScreen(
            items: [EditedMedia(file: photo, isVideo: false, aspectRatio: 1)],
            mode: ComposeMode.story,
          ),
        ),
      );
      await _frames(t, 3);
      expect(find.text('Only on your profile'), findsNothing);
      expect(find.byKey(const ValueKey('audience')), findsOneWidget);
      await t.scrollUntilVisible(
        find.byKey(const ValueKey('share-to-highlight')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.byKey(const ValueKey('share-to-highlight')));
      await _frames(t, 10);
      expect(find.text('Add to highlight'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('hl-choose-h1')));
      await _frames(t, 10);
      expect(find.text('Highlight: Goa'), findsOneWidget);
      // a highlight has no audience
      expect(find.byKey(const ValueKey('audience')), findsNothing);
      // new one by name
      await t.tap(find.byKey(const ValueKey('share-to-highlight')));
      await _frames(t, 10);
      await t.enterText(find.byKey(const ValueKey('hl-new-name')), '  Trip  ');
      await t.tap(find.byKey(const ValueKey('hl-new-create')));
      await _frames(t, 10);
      expect(find.text('Highlight: Trip'), findsOneWidget);
      // back to a normal moment
      await t.tap(find.byKey(const ValueKey('share-to-moment')));
      await _frames(t, 3);
      expect(find.text('Highlight only'), findsOneWidget);
      expect(find.byKey(const ValueKey('audience')), findsOneWidget);
      await _finish(t);
    });
  });

  // -------------------------------------------------------- chat fonts
  group('chat fonts', () {
    test('message font field', () {
      final m = Message.fromMap('m', {
        'senderId': 'a',
        'text': 'hey',
        'font': 'comic',
        'createdAt': Timestamp.fromDate(_t0),
      });
      expect(m.font, 'comic');
      expect(Message.fromMap('m', const {'senderId': 'a'}).font, '');
    });

    testWidgets('bubble shows the sender\'s font', (t) async {
      final m = Message(
        id: 'm',
        senderId: 'a',
        text: 'fancy hello',
        createdAt: _t0,
        font: 'vibes',
      );
      await t.pumpWidget(
        _app(
          MessageBubble(
            message: m,
            mine: false,
            myUid: 'me',
            otherName: 'amit',
          ),
        ),
      );
      await t.pump();
      final txt = t.widget<Text>(find.text('fancy hello'));
      expect(txt.style!.fontFamily, 'BioVibes');
      await _finish(t);
    });
  });

  // ------------------------------------------------ text fonts (editor)
  group('text fonts on moments / posts', () {
    test('overlay font saved and read back', () {
      const o = VideoOverlay(
        kind: VideoOverlay.textKind,
        text: 'hi',
        font: 'neon',
      );
      final m = o.toMap();
      expect(m['f'], 'neon');
      expect(VideoOverlay.fromMap(m)!.font, 'neon');
      expect(
        const VideoOverlay(
          kind: VideoOverlay.textKind,
          text: 'x',
        ).toMap().containsKey('f'),
        isFalse,
      );
      expect(o.copyWith(text: 'yo').font, 'neon');
    });

    testWidgets('overlay text uses the font', (t) async {
      await t.pumpWidget(
        _app(
          const OverlayView(
            overlay: VideoOverlay(
              kind: VideoOverlay.textKind,
              text: 'party',
              font: 'bangers',
            ),
            frameWidth: 300,
          ),
        ),
      );
      final txt = t.widget<Text>(find.text('party'));
      expect(txt.style!.fontFamily, 'BioBangers');
      await _finish(t);
    });
  });

  // ------------------------------------------------------- more stickers
  group('more stickers', () {
    test('194 stickers, 69 animated, every file there, all searchable', () {
      final ids = StickerPack.ids;
      expect(ids.toSet().length, ids.length, reason: 'no doubles');
      expect(ids.length, 194);
      expect(ids.where(StickerPack.isAnimated).length, 69);
      for (final id in ids) {
        final f = File(
          'assets/stickers/$id.${StickerPack.isAnimated(id) ? 'webp' : 'png'}',
        );
        expect(f.existsSync(), isTrue, reason: f.path);
        expect(StickerPack.tags.containsKey(id), isTrue, reason: id);
      }
      expect(StickerPack.search('confetti'), contains('a_confetti'));
      expect(StickerPack.search('cricket'), contains('cricket'));
      expect(StickerPack.search('hindi'), contains('hi_holi'));
    });
  });

  // ----------------------------------------------------- custom app icon
  group('custom app icon', () {
    tearDown(() {
      AppIcons.debugGet = null;
      AppIcons.debugSet = null;
      AppIcons.debugPin = null;
      AppIconScreen.debugPickPicture = null;
    });

    Uint8List redPhoto() {
      final p = img.Image(width: 300, height: 200);
      img.fill(p, color: img.ColorRgb8(220, 20, 30));
      return img.encodePng(p);
    }

    test('photo -> square icon picture', () {
      final png = AppIcons.customIconPng(redPhoto())!;
      final out = img.decodePng(png)!;
      expect(out.width, AppIcons.customSize);
      expect(out.height, AppIcons.customSize);
      final mid = out.getPixel(216, 216);
      expect(mid.r, 220);
      expect(mid.g, 20);
      // the border is the photo's edge colour (no black corners)
      expect(out.getPixel(2, 2).r, greaterThan(200));
      expect(AppIcons.customIconPng(Uint8List.fromList([1, 2, 3])), isNull);
    });

    testWidgets('Custom tile: explain, pick, add to home screen', (t) async {
      Uint8List? pinned;
      AppIcons.debugGet = () async => 'default';
      AppIcons.debugPin = (png) async {
        pinned = png;
        return true;
      };
      final photo = redPhoto();
      AppIconScreen.debugPickPicture = () async => photo;
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.5;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(theme: AppTheme.dark, home: const AppIconScreen()),
      );
      await t.pumpAndSettle();
      expect(find.text('Custom'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('app-icon-custom')));
      await t.pumpAndSettle();
      expect(find.textContaining('app list stays the same'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('custom-icon-pick')));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1500)),
      );
      await t.pumpAndSettle();
      for (var i = 0; i < 20 && pinned == null; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await t.pump();
      }
      expect(pinned, isNotNull);
      await t.pumpAndSettle();
      expect(find.textContaining('Check your home screen'), findsOneWidget);
      await _finish(t);
    });
  });
}
