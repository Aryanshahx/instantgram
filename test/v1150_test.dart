import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:instantgram/core/l10n.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/comment.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/models/story.dart';
import 'package:instantgram/screens/post/editor_screen.dart';
import 'package:instantgram/services/giphy.dart';
import 'package:instantgram/services/overlay_painter.dart';
import 'package:instantgram/widgets/comment_tile.dart';
import 'package:instantgram/widgets/hold_haptics.dart';
import 'package:instantgram/widgets/overlay_tools.dart';
import 'package:instantgram/widgets/reel_actions.dart';
import 'package:instantgram/widgets/trim_timeline.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.body);
  final Object body;
  Uri? last;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    last = options.uri;
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Comment _c(
  String id, {
  String parent = '',
  int minute = 0,
  String text = 'hi',
  bool edited = false,
  int likes = 0,
  String gif = '',
  String clip = '',
}) => Comment(
  id: id,
  authorId: 'u_$id',
  authorUsername: 'name_$id',
  authorPhotoUrl: '',
  text: text,
  createdAt: DateTime(2026, 1, 1, 12, minute),
  parentId: parent,
  replyToUsername: parent.isEmpty ? '' : 'someone',
  edited: edited,
  likeCount: likes,
  gifUrl: gif,
  clipId: clip,
);

Future<void> _settle(WidgetTester t, bool Function() done) async {
  for (var i = 0; i < 30 && !done(); i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await t.pump(const Duration(milliseconds: 100));
  }
}

bool Function() _closed = () => false;
EditorResult? Function() _result = () => null;

void main() {
  setUp(() => debugStickerClient = GiphyClient(key: ''));
  group('comment threads', () {
    test('replies sit under their comment, newest comment first', () {
      final threads = buildThreads([
        _c('r2', parent: 'a', minute: 5),
        _c('b', minute: 3),
        _c('a', minute: 1),
        _c('r1', parent: 'a', minute: 2),
      ]);
      expect(threads.map((t) => t.root.id), ['b', 'a']);
      expect(threads[1].replies.map((r) => r.id), ['r1', 'r2']);
      expect(threads[0].replies, isEmpty);
    });

    test('a reply whose comment is gone shows as a comment', () {
      final threads = buildThreads([_c('x', parent: 'deleted'), _c('y')]);
      expect(threads.length, 2);
    });

    test('summary and kinds', () {
      expect(_c('a', text: '  hello ').summary, 'hello');
      expect(_c('a', text: '', gif: 'https://g/x.gif').summary, 'GIF');
      expect(_c('a', text: '', gif: 'https://g/x.gif').hasGif, isTrue);
      expect(_c('a', text: '', clip: 'p1').hasClip, isTrue);
      expect(_c('a', parent: 'p').isReply, isTrue);
      final e = _c('a').copyWith(text: 'new', edited: true, likeCount: 3);
      expect((e.text, e.edited, e.likeCount), ('new', true, 3));
    });
  });

  group('a comment', () {
    Future<void> show(
      WidgetTester t,
      Comment c, {
      VoidCallback? onMenu,
      VoidCallback? onReply,
      Future<void> Function(bool)? setLiked,
      VoidCallback? onClip,
    }) async {
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(12),
              child: CommentTile(
                comment: c,
                postId: 'p',
                onReply: onReply ?? () {},
                onMenu: onMenu ?? () {},
                onOpenProfile: () {},
                onOpenClip: onClip ?? () {},
                loadLiked: () async => false,
                setLiked: setLiked ?? (_) async {},
              ),
            ),
          ),
        ),
      );
      await t.pump();
    }

    testWidgets('shows the edited mark and the person that is answered', (
      t,
    ) async {
      await show(t, _c('a', parent: 'p', edited: true, text: 'thanks'));
      expect(find.byKey(const ValueKey('editedMark')), findsOneWidget);
      expect(find.textContaining('@someone'), findsOneWidget);
      await show(t, _c('b', text: 'plain'));
      expect(find.byKey(const ValueKey('editedMark')), findsNothing);
    });

    testWidgets('the heart counts up, and down again', (t) async {
      final sent = <bool>[];
      await show(
        t,
        _c('a', likes: 4),
        setLiked: (v) async => sent.add(v),
      );
      expect(find.text('4'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('commentLike')));
      await t.pump();
      expect(find.text('5'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('commentLike')));
      await t.pump();
      expect(find.text('4'), findsOneWidget);
      expect(sent, [true, false]);
    });

    testWidgets('Reply, a long press and the clip answer all react', (t) async {
      var replied = 0, menu = 0, clip = 0;
      await show(
        t,
        _c('a', text: '', clip: 'p9'),
        onReply: () => replied++,
        onMenu: () => menu++,
        onClip: () => clip++,
      );
      await t.tap(find.byKey(const ValueKey('reply_a')));
      await t.longPress(find.byType(CommentTile));
      await t.tap(find.byKey(const ValueKey('commentClip')));
      expect((replied, menu, clip), (1, 1, 1));
    });

    testWidgets('the long-press menu: edit for the author, delete for the owner', (
      t,
    ) async {
      Future<void> open(bool edit, bool del, bool report) async {
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => TextButton(
                  onPressed: () => showCommentMenu(
                    ctx,
                    canEdit: edit,
                    canDelete: del,
                    canReport: report,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.text('open'));
        await t.pump(const Duration(milliseconds: 500));
      }

      ValueKey<String> k(String n) => ValueKey('commentMenu_$n');
      await open(true, true, false);
      for (final n in ['reply', 'replyWithClip', 'share', 'edit', 'delete']) {
        expect(find.byKey(k(n)), findsOneWidget, reason: n);
      }
      expect(find.byKey(k('report')), findsNothing);
      await t.tapAt(const Offset(10, 10));
      await t.pump(const Duration(milliseconds: 500));
      await open(false, false, true);
      expect(find.byKey(k('report')), findsOneWidget);
      expect(find.byKey(k('edit')), findsNothing);
      expect(find.byKey(k('delete')), findsNothing);
    });
  });

  group('the clip timeline', () {
    final calls = <(double, double, bool)>[];
    final seeks = <double>[];

    Future<void> show(
      WidgetTester t, {
      int? max,
      String? audio,
      double start = 2,
      double end = 12,
    }) async {
      calls.clear();
      seeks.clear();
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: TrimTimeline(
                  total: 20,
                  start: start,
                  end: end,
                  position: ValueNotifier(5),
                  frames: List<Uint8List?>.filled(8, null),
                  maxSeconds: max,
                  audioLabel: audio,
                  onRange: (s, e, m) => calls.add((s, e, m)),
                  onSeek: seeks.add,
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump();
    }

    testWidgets('dragging the end handle snaps to whole seconds', (t) async {
      await show(t);
      final tl = t.getTopLeft(find.byKey(const ValueKey('trimTimeline')));
      await t.dragFrom(tl + const Offset(245, 40), const Offset(92, 0));
      expect(calls, isNotEmpty);
      final last = calls.last;
      expect(last.$1, 2);
      expect(last.$2, 17);
      expect(last.$3, isFalse);
      for (final c in calls) {
        expect(c.$2, c.$2.roundToDouble());
      }
    });

    testWidgets('dragging the start handle moves the start', (t) async {
      await show(t);
      final tl = t.getTopLeft(find.byKey(const ValueKey('trimTimeline')));
      await t.dragFrom(tl + const Offset(45, 40), const Offset(100, 0));
      expect(calls.last, (7.0, 12.0, true));
    });

    testWidgets('the length limit holds', (t) async {
      await show(t, max: 10);
      final tl = t.getTopLeft(find.byKey(const ValueKey('trimTimeline')));
      await t.dragFrom(tl + const Offset(245, 40), const Offset(90, 0));
      expect(calls, isEmpty, reason: 'already 10 s, the end cannot go further');
      expect(find.textContaining('max 10s'), findsOneWidget);
    });

    testWidgets('a tap on the strip scrubs the playhead', (t) async {
      await show(t);
      final tl = t.getTopLeft(find.byKey(const ValueKey('trimTimeline')));
      await t.tapAt(tl + const Offset(200, 40));
      expect(seeks.last, closeTo(10, 0.1));
      expect(find.byKey(const ValueKey('playhead')), findsOneWidget);
    });

    testWidgets('times and the audio lane are written out', (t) async {
      await show(t, audio: 'Sunrise');
      expect(find.text('0:02'), findsOneWidget);
      expect(find.text('0:12'), findsOneWidget);
      expect(find.text('10s'), findsOneWidget);
      expect(find.byKey(const ValueKey('audioLane')), findsOneWidget);
      expect(find.text('Sunrise'), findsOneWidget);
      await show(t);
      expect(find.byKey(const ValueKey('audioLane')), findsNothing);
      expect(clockText(75), '1:15');
    });
  });

  group('picture stickers', () {
    const sticker = StoryOverlay(
      text: 'sticker',
      image: 'https://media.giphy.com/s.gif',
      still: 'https://media.giphy.com/s_still.gif',
      aspect: 1.5,
      scale: 1.2,
    );

    test('are stored and read back, and a plain http link is refused', () {
      final back = StoryOverlay.fromMap(sticker.toMap())!;
      expect(back.isImage, isTrue);
      expect(back.image, sticker.image);
      expect(back.still, sticker.still);
      expect(back.aspect, 1.5);
      final bad = StoryOverlay.fromMap({
        't': 'sticker',
        'i': 'http://insecure/x.gif',
      })!;
      expect(bad.isImage, isFalse);
      expect(const StoryOverlay(text: 'a').toMap().containsKey('i'), isFalse);
      expect(sticker.copyWith(scale: 2).image, sticker.image);
      expect(sticker.fontSize(100), closeTo(36 * 1.2, 1e-9));
    });

    testWidgets('show as a picture over the media', (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: SizedBox(
            width: 300,
            height: 300,
            child: OverlayShow(
              overlays: [sticker],
              child: ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('imageSticker')), findsOneWidget);
    });

    testWidgets('are painted into a photo from a loaded picture', (t) async {
      late ui.Image pic;
      await t.runAsync(() async {
        final rec = ui.PictureRecorder();
        Canvas(rec).drawRect(
          const Rect.fromLTWH(0, 0, 20, 20),
          Paint()..color = const Color(0xFFFFFFFF),
        );
        pic = await rec.endRecording().toImage(20, 20);
        final out = ui.PictureRecorder();
        paintOverlays(
          Canvas(out),
          const Size(100, 100),
          [sticker],
          images: {sticker.still: pic},
        );
        final done = await out.endRecording().toImage(100, 100);
        final data = await done.toByteData(format: ui.ImageByteFormat.rawRgba);
        var lit = 0;
        for (var i = 0; i < data!.lengthInBytes; i += 4) {
          if (data.getUint8(i) > 200) lit++;
        }
        expect(lit, greaterThan(300), reason: 'the white sticker was drawn');
      });
    });

    test('the Giphy client can ask for stickers', () async {
      final adapter = _Adapter({'data': []});
      final dio = Dio()..httpClientAdapter = adapter;
      await GiphyClient(dio: dio, key: 'k', stickers: true).search('cat');
      expect(adapter.last!.path, contains('/v1/stickers/search'));
      expect(adapter.last!.queryParameters.containsKey('bundle'), isFalse);
      await GiphyClient(dio: dio, key: 'k').search('cat');
      expect(adapter.last!.path, contains('/v1/gifs/search'));
    });

    testWidgets('the sheet has Stickers and Emoji when Giphy is set up', (
      t,
    ) async {
      Map<String, dynamic> entry(String id) => {
        'id': id,
        'images': {
          'fixed_width': {'url': 'https://m/$id.gif', 'width': '200', 'height': '100'},
          'fixed_width_small': {'url': 'https://m/$id-s.gif'},
          'fixed_width_still': {'url': 'https://m/$id-still.gif'},
        },
      };
      final dio = Dio()
        ..httpClientAdapter = _Adapter({
          'data': [entry('a')],
        });
      StoryOverlay? picked;
      await t.binding.setSurfaceSize(const Size(500, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () async => picked = await showStickerSheet(
                  ctx,
                  client: GiphyClient(dio: dio, key: 'k', stickers: true),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pump(const Duration(milliseconds: 500));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Stickers'), findsOneWidget);
      expect(find.text('Emoji'), findsOneWidget);
      expect(find.byKey(const ValueKey('sticker_a')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('sticker_a')));
      await t.pump(const Duration(milliseconds: 500));
      expect(picked!.isImage, isTrue);
      expect(picked!.image, 'https://m/a.gif');
      expect(picked!.still, 'https://m/a-still.gif');
      expect(picked!.aspect, 2);
    });

    testWidgets('without a key only emoji are offered', (t) async {
      StoryOverlay? picked;
      await t.binding.setSurfaceSize(const Size(500, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () async => picked = await showStickerSheet(
                  ctx,
                  client: GiphyClient(key: ''),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(seconds: 1));
      expect(find.byType(TabBar), findsNothing);
      await t.ensureVisible(find.byKey(const ValueKey('emoji_🔥')));
      await t.tap(find.byKey(const ValueKey('emoji_🔥')));
      await t.pump(const Duration(milliseconds: 500));
      expect(picked!.emoji, isTrue);
      expect(picked!.text, '🔥');
    });
  });

  group('the editor: selecting and resizing', () {
    Future<File> photo() async {
      final dir = Directory.systemTemp.createTempSync('editor15');
      addTearDown(() => dir.deleteSync(recursive: true));
      final src = File('${dir.path}/p.jpg');
      final im = img.Image(width: 80, height: 40);
      for (final p in im) {
        p.r = 200;
        p.g = 100;
        p.b = 50;
      }
      src.writeAsBytesSync(img.encodeJpg(im, quality: 95));
      return src;
    }

    Future<void> open(WidgetTester t, File file) async {
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
                      MaterialPageRoute(builder: (_) => EditorScreen(file: file, video: false)),
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
      _closed = () => closed;
      _result = () => result;
    }

    Future<void> addEmoji(WidgetTester t) async {
      await t.tap(find.byKey(const ValueKey('tool_stickers')));
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
      await t.ensureVisible(find.byKey(const ValueKey('emoji_🔥')));
      await t.tap(find.byKey(const ValueKey('emoji_🔥')));
      await t.pump(const Duration(seconds: 1));
    }

    testWidgets('a new sticker is selected: frame, handle, size bar; bigger and smaller', (
      t,
    ) async {
      await open(t, await photo());
      await addEmoji(t);
      expect(find.byKey(const ValueKey('selectionBar')), findsOneWidget);
      expect(find.byKey(const ValueKey('selectedFrame')), findsOneWidget);
      expect(find.byKey(const ValueKey('resizeHandle')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('sizeUp')));
      await t.tap(find.byKey(const ValueKey('sizeUp')));
      await t.tap(find.byKey(const ValueKey('sizeDown')));
      await t.pump();
      // the slider moves it too
      final slider = find.byKey(const ValueKey('sizeSlider'));
      await t.drag(slider, const Offset(40, 0));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('selDone')));
      await t.pump();
      expect(find.byKey(const ValueKey('selectionBar')), findsNothing);
      await t.tap(find.byKey(const ValueKey('editorDone')));
      await t.pump(const Duration(milliseconds: 300));
      await _settle(t, _closed);
      final o = _result()!.overlays.single;
      expect(o.scale, greaterThan(1.15), reason: 'bigger than it started');
    });

    testWidgets('dragging the corner handle resizes', (t) async {
      await open(t, await photo());
      await addEmoji(t);
      await t.drag(find.byKey(const ValueKey('resizeHandle')), const Offset(60, 60));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('selDone')));
      await t.tap(find.byKey(const ValueKey('editorDone')));
      await t.pump(const Duration(milliseconds: 300));
      await _settle(t, _closed);
      expect(_result()!.overlays.single.scale, greaterThan(1.3));
    });

    testWidgets('delete removes the selected sticker', (t) async {
      await open(t, await photo());
      await addEmoji(t);
      expect(find.byKey(const ValueKey('overlay0')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('selDelete')));
      await t.pump();
      expect(find.byKey(const ValueKey('overlay0')), findsNothing);
      expect(find.byKey(const ValueKey('selectionBar')), findsNothing);
    });

    testWidgets('a text is selected by a tap and can be edited from the bar', (
      t,
    ) async {
      await open(t, await photo());
      await t.tap(find.byKey(const ValueKey('tool_text')));
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
      await t.enterText(find.byKey(const ValueKey('storyTextInput')), 'Hello');
      await t.tap(find.byKey(const ValueKey('storyTextDone')));
      await t.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('overlay0')), findsOneWidget);
      expect(find.byKey(const ValueKey('selectionBar')), findsNothing);
      await t.tap(find.byKey(const ValueKey('drag0')));
      await t.pump();
      expect(find.byKey(const ValueKey('selectionBar')), findsOneWidget);
      expect(find.byKey(const ValueKey('selEdit')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('selEdit')));
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('storyTextInput')), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('storyTextInput')), 'Hi there');
      await t.tap(find.byKey(const ValueKey('storyTextDone')));
      await t.pump(const Duration(seconds: 1));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('overlay0')),
          matching: find.text('Hi there'),
        ),
        findsOneWidget,
      );
    });
  });

  group('press and hold', () {
    Future<void> pump(WidgetTester t, void Function() onHold) async {
      await t.pumpWidget(
        MaterialApp(
          home: HoldHaptics(
            onHold: onHold,
            child: const Scaffold(body: Center(child: Text('hold me'))),
          ),
        ),
      );
    }

    testWidgets('a held finger buzzes once', (t) async {
      var n = 0;
      await pump(t, () => n++);
      final g = await t.startGesture(t.getCenter(find.text('hold me')));
      await t.pump(const Duration(milliseconds: 300));
      expect(n, 0);
      await t.pump(const Duration(milliseconds: 400));
      expect(n, 1);
      await g.up();
      await t.pump(const Duration(seconds: 2));
      expect(n, 1);
    });

    testWidgets('a quick tap, a scroll and a pinch do not', (t) async {
      var n = 0;
      await pump(t, () => n++);
      final c = t.getCenter(find.text('hold me'));
      await t.tapAt(c);
      await t.pump(const Duration(seconds: 1));
      final g = await t.startGesture(c);
      await g.moveBy(const Offset(0, 60));
      await t.pump(const Duration(seconds: 1));
      await g.up();
      final a = await t.startGesture(c);
      final b = await t.startGesture(c + const Offset(40, 0));
      await t.pump(const Duration(seconds: 1));
      await a.up();
      await b.up();
      expect(n, 0);
    });
  });

  group('words', () {
    test('every language has the new comment, sticker and button words', () {
      for (final l in kLanguages.where((l) => l.code != 'en')) {
        final lang = Language.instance..value = l.code;
        for (final w in [
          'Reply',
          'Reply with a clip',
          'View replies',
          'Add a comment...',
          'Search stickers',
          'Follow',
          'Save',
        ]) {
          expect(lang.translate(w), isNot(w), reason: '${l.code}: $w');
        }
      }
      Language.instance.value = 'en';
    });

    test('a report about a comment says so', () {
      final uri = reportUri(
        _post(),
        reason: 'Spam',
        details: 'rude',
        about: 'c1 by @bob: nasty words',
      );
      final text = Uri.decodeComponent(uri.toString());
      expect(text, contains('report this comment'));
      expect(text, contains('c1 by @bob: nasty words'));
    });
  });
}

Post _post() => Post(
  id: 'p1',
  authorId: 'other',
  authorUsername: 'name',
  authorPhotoUrl: '',
  type: 'video',
  caption: 'hello',
  createdAt: DateTime(2026),
  videoRef: 'm:video/u/aaaaaaaaaaaaaaaa.mp4',
);
