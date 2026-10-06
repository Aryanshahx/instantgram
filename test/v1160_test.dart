import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/config.dart' show kMaxVideoSeconds;
import 'package:instantgram/core/countries.dart';
import 'package:instantgram/core/l10n.dart';
import 'package:instantgram/core/legal.dart';
import 'package:instantgram/core/limits.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/app_user.dart';
import 'package:instantgram/models/comment.dart';
import 'package:instantgram/models/finish.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/models/story.dart';
import 'package:instantgram/screens/auth/language_step_screen.dart';
import 'package:instantgram/screens/auth/signup_screen.dart';
import 'package:instantgram/screens/profile/share_profile_screen.dart';
import 'package:instantgram/screens/story/story_composer.dart';
import 'package:instantgram/services/giphy.dart';
import 'package:instantgram/services/playhead.dart';
import 'package:instantgram/widgets/comment_tile.dart';
import 'package:instantgram/widgets/overlay_tools.dart';
import 'package:instantgram/widgets/repost_controller.dart';
import 'package:instantgram/widgets/trim_timeline.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:video_player/video_player.dart';

Comment _c(
  String id, {
  int minute = 0,
  bool pinned = false,
  String parent = '',
}) => Comment(
  id: id,
  authorId: 'u_$id',
  authorUsername: 'name_$id',
  authorPhotoUrl: '',
  text: 'text $id',
  createdAt: DateTime(2026, 1, 1, 12, minute),
  parentId: parent,
  pinned: pinned,
);

Post _post({int reposts = 0}) => Post(
  id: 'p1',
  authorId: 'other',
  authorUsername: 'name',
  authorPhotoUrl: '',
  type: 'video',
  caption: 'hello',
  createdAt: DateTime(2026),
  videoRef: 'm:video/u/aaaaaaaaaaaaaaaa.mp4',
  repostCount: reposts,
);

Widget _app(Widget child) => MaterialApp(theme: AppTheme.dark, home: child);

void main() {
  setUp(() => debugStickerClient = GiphyClient(key: ''));

  group('countries', () {
    test('codes are unique, a flag is built from the code', () {
      expect(kCountries.length, greaterThan(190));
      expect({for (final c in kCountries) c.code}.length, kCountries.length);
      expect(countryForCode('in')?.name, 'India');
      expect(countryForCode('IN')!.flag, '\u{1F1EE}\u{1F1F3}');
      expect(countryForCode('ZZ'), isNull);
      expect(countryForCode(null), isNull);
    });

    test('search by name or code', () {
      expect(searchCountries('').length, kCountries.length);
      expect(
        searchCountries('united').map((c) => c.code),
        containsAll(['US', 'GB', 'AE']),
      );
      expect(searchCountries('ind').map((c) => c.code), contains('IN'));
      expect(searchCountries('xyzxyz'), isEmpty);
    });
  });

  group('legal and limits', () {
    test('the pages live next to each other', () {
      expect(kPrivacyUrl, endsWith('/privacy.html'));
      expect(kTermsUrl, endsWith('/terms.html'));
      expect(kPrivacyUrl.startsWith(kLegalBaseUrl), isTrue);
      expect(File('docs/privacy.md').existsSync(), isTrue);
      expect(File('docs/terms.md').existsSync(), isTrue);
      expect(File('docs/profile.html').existsSync(), isTrue);
      expect(File('docs/privacy.html').existsSync(), isFalse);
      expect(File('docs/terms.html').existsSync(), isFalse);
    });

    test('the markdown pages carry front matter for GitHub Pages', () {
      for (final f in ['docs/privacy.md', 'docs/terms.md']) {
        final text = File(f).readAsStringSync();
        expect(text.startsWith('---\nlayout: default\n'), isTrue, reason: f);
        expect(text, contains('techlabs.hyper@gmail.com'));
      }
      expect(File('docs/_config.yml').readAsStringSync(), contains('theme:'));
    });

    test('a profile link carries the username', () {
      expect(
        profileLinkFor('aryan.s'),
        '$kLegalBaseUrl/profile.html?u=aryan.s',
      );
      expect(profileShareText('aryan.s'), contains('@aryan.s'));
      expect(profileShareText('aryan.s'), contains(profileLinkFor('aryan.s')));
    });

    testWidgets('when the browser cannot open, the in-app page is used', (
      t,
    ) async {
      var fallback = 0;
      late BuildContext ctx;
      await t.pumpWidget(
        _app(
          Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      );
      await t.runAsync(() => openLegal(ctx, kPrivacyUrl, () => fallback++));
      expect(fallback, 1);
    });

    test('videos are limited to one minute', () {
      expect(kMaxVideoSeconds, 60);
      expect(isVideoTooLong(59000), isFalse);
      expect(isVideoTooLong(60020), isFalse, reason: 'phones report 60.02 s');
      expect(isVideoTooLong(61500), isTrue);
      expect(videoTooLongMessage(83000), contains('1:23'));
      expect(videoTooLongMessage(83000), contains('1 minute'));
    });
  });

  group('sign-up flow', () {
    testWidgets('the language step comes first and Continue opens the form', (
      t,
    ) async {
      t.view.physicalSize = const Size(800, 1600);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(const LanguageStepScreen()));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('langStepTitle')), findsOneWidget);
      expect(find.byKey(const ValueKey('language_en')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('language_hi')));
      await t.pump();
      expect(Language.instance.value, 'hi');
      await t.enterText(find.byKey(const ValueKey('languageSearch')), 'span');
      await t.pump();
      expect(find.byKey(const ValueKey('language_es')), findsOneWidget);
      expect(find.byKey(const ValueKey('language_hi')), findsNothing);
      await t.tap(find.byKey(const ValueKey('langContinue')));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(SignupScreen), findsOneWidget);
      Language.instance.value = 'en';
    });

    testWidgets('country is searchable; the box must be ticked', (t) async {
      t.view.physicalSize = const Size(800, 2000);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(const SignupScreen()));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('agreeBox')), findsOneWidget);
      expect(
        find.textContaining('Privacy policy', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Terms of use', findRichText: true),
        findsOneWidget,
      );

      // pick a country from the search sheet
      await t.ensureVisible(find.byKey(const ValueKey('countryField')));
      await t.tap(find.byKey(const ValueKey('countryField')));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      await t.enterText(find.byKey(const ValueKey('countrySearch')), 'neth');
      await t.pump();
      expect(find.byKey(const ValueKey('country_NL')), findsOneWidget);
      expect(find.byKey(const ValueKey('country_IN')), findsNothing);
      await t.tap(find.byKey(const ValueKey('country_NL')));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Netherlands'), findsOneWidget);

      // without the tick sign-up says why it does not go on
      final create = find.widgetWithText(FilledButton, 'Create account');
      await t.ensureVisible(create);
      await t.tap(create);
      await t.pump();
      expect(find.byKey(const ValueKey('agreeError')), findsOneWidget);
      await t.ensureVisible(find.byKey(const ValueKey('agreeBox')));
      await t.tap(find.byKey(const ValueKey('agreeBox')));
      await t.pump();
      expect(find.byKey(const ValueKey('agreeError')), findsNothing);
      expect(t.takeException(), isNull);
    });

    test('the user document carries the country', () {
      const u = AppUser(uid: 'u', username: 'a', country: 'IN');
      expect(u.country, 'IN');
    });
  });

  group('pinned comments', () {
    test('pinned comments are first, then newest first', () {
      final threads = buildThreads([
        _c('new', minute: 9),
        _c('old', minute: 1, pinned: true),
        _c('mid', minute: 5),
        _c('pin2', minute: 3, pinned: true),
      ]);
      expect(threads.map((t) => t.root.id), ['pin2', 'old', 'new', 'mid']);
      expect(kMaxPinnedComments, 3);
      expect(_c('a', pinned: true).copyWith(pinned: false).pinned, isFalse);
    });

    testWidgets('a pinned comment says Pinned', (t) async {
      await t.pumpWidget(
        _app(
          Scaffold(
            body: CommentTile(
              comment: _c('a', pinned: true),
              postId: 'p',
              onReply: () {},
              onMenu: () {},
              onOpenProfile: () {},
              onOpenClip: () {},
              loadLiked: () async => false,
              setLiked: (_) async {},
            ),
          ),
        ),
      );
      await t.pump();
      expect(find.byKey(const ValueKey('pinnedMark')), findsOneWidget);
      expect(find.text('Pinned'), findsOneWidget);
    });

    Future<void> openMenu(
      WidgetTester t, {
      required bool canPin,
      bool pinned = false,
    }) async {
      await t.pumpWidget(
        _app(
          Builder(
            builder: (c) => Scaffold(
              body: TextButton(
                onPressed: () => showCommentMenu(
                  c,
                  canEdit: false,
                  canDelete: true,
                  canReport: false,
                  canPin: canPin,
                  pinned: pinned,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
    }

    testWidgets('the owner of the post gets Pin / Unpin, others do not', (
      t,
    ) async {
      await openMenu(t, canPin: true);
      expect(find.byKey(const ValueKey('commentMenu_pin')), findsOneWidget);
      expect(find.byKey(const ValueKey('commentMenu_unpin')), findsNothing);
    });

    testWidgets('a pinned comment offers Unpin', (t) async {
      await openMenu(t, canPin: true, pinned: true);
      expect(find.byKey(const ValueKey('commentMenu_unpin')), findsOneWidget);
    });

    testWidgets('other people see no Pin', (t) async {
      await openMenu(t, canPin: false);
      expect(find.byKey(const ValueKey('commentMenu_pin')), findsNothing);
    });

    test('the rules let only the owner of the post change pinned', () {
      final rules = File('firebase/firestore.rules').readAsStringSync();
      expect(rules, contains("hasOnly(['pinned'])"));
      expect(
        rules,
        contains('posts/\$(postId)).data.authorId == request.auth.uid &&'),
      );
    });
  });

  group('repost counts', () {
    test(
      'the count starts from the post and follows the tap, and rolls back',
      () async {
        final c = RepostController(
          _post(reposts: 4),
          loader: (_) async => false,
        );
        expect(c.count, 4);
        final err = await c.toggle(); // no database in tests: the write fails
        expect(err, isNotNull);
        expect(c.count, 4);
        expect(c.reposted, isFalse);
        c.dispose();
      },
    );
  });

  group('overlay timing', () {
    test('a text knows when it is shown', () {
      const always = StoryOverlay(text: 'a');
      expect(always.isAlways, isTrue);
      expect(always.visibleAt(99), isTrue);
      const part = StoryOverlay(text: 'a', from: 2, to: 5);
      expect(part.isAlways, isFalse);
      expect(part.visibleAt(1), isFalse);
      expect(part.visibleAt(2), isTrue);
      expect(part.visibleAt(5), isTrue);
      expect(part.visibleAt(5.5), isFalse);
      const fromOnly = StoryOverlay(text: 'a', from: 3);
      expect(fromOnly.visibleAt(100), isTrue);
    });

    test('times survive the trip to the database and back', () {
      final o = const StoryOverlay(
        text: 'x',
        from: 1.5,
        to: 4,
      ).copyWith(scale: 2);
      final back = StoryOverlay.fromMap(jsonDecode(jsonEncode(o.toMap())))!;
      expect(back.from, 1.5);
      expect(back.to, 4);
      expect(back.scale, 2);
      final plain = StoryOverlay.fromMap(
        const StoryOverlay(text: 'y').toMap(),
      )!;
      expect(plain.isAlways, isTrue);
      expect(const StoryOverlay(text: 'y').toMap().containsKey('ts'), isFalse);
      final fin = MediaFinish.fromMap(
        jsonDecode(jsonEncode(MediaFinish(overlays: [o]).toMap())),
      )!;
      expect(fin.overlays.single.to, 4);
    });

    test('old items without times are shown all the time', () {
      final o = StoryOverlay.fromMap({'t': 'old', 'x': 0.5, 'y': 0.5})!;
      expect(o.isAlways, isTrue);
      expect(overlayMask([o, const StoryOverlay(text: 'b', from: 9)], 1), [
        true,
        false,
      ]);
    });

    testWidgets('a viewer shows each text only in its seconds', (t) async {
      final player = ValueNotifier<VideoPlayerValue>(
        const VideoPlayerValue(
          duration: Duration(seconds: 10),
          position: Duration(seconds: 1),
          isInitialized: true,
        ),
      );
      await t.pumpWidget(
        _app(
          SizedBox(
            width: 300,
            height: 500,
            child: OverlayShow(
              player: player,
              overlays: const [
                StoryOverlay(text: 'always'),
                StoryOverlay(text: 'middle', from: 3, to: 6),
              ],
              child: const ColoredBox(color: Colors.black),
            ),
          ),
        ),
      );
      await t.pump();
      expect(find.text('always'), findsOneWidget);
      expect(find.text('middle'), findsNothing);
      player.value = player.value.copyWith(
        position: const Duration(seconds: 4),
      );
      await t.pump();
      expect(find.text('middle'), findsOneWidget);
      player.value = player.value.copyWith(
        position: const Duration(seconds: 8),
      );
      await t.pump();
      expect(find.text('middle'), findsNothing);
      expect(find.text('always'), findsOneWidget);
    });
  });

  group('smooth timeline', () {
    test('the playhead moves between the reports of the player', () {
      final s = PlayheadSmoother();
      s.report(2, true, const Duration(seconds: 10));
      expect(s.value(const Duration(seconds: 10)), 2);
      expect(
        s.value(const Duration(milliseconds: 10250)),
        closeTo(2.25, 0.001),
      );
      // a normal report next to the estimate is blended in, never a step back
      s.report(2.6, true, const Duration(milliseconds: 10500));
      expect(
        s.value(const Duration(milliseconds: 10500)),
        closeTo(2.5 + 0.1 * 0.15, 0.01),
      );
    });

    test('paused it stands still; a seek is taken over at once', () {
      final s = PlayheadSmoother();
      s.report(3, false, const Duration(seconds: 1));
      expect(s.value(const Duration(seconds: 5)), 3);
      s.report(3, true, const Duration(seconds: 5));
      s.report(9, true, const Duration(milliseconds: 5100));
      expect(s.value(const Duration(milliseconds: 5100)), 9);
      s.seek(1, const Duration(seconds: 6));
      expect(s.value(const Duration(milliseconds: 6500)), closeTo(1.5, 0.001));
    });

    test(
      'seeks while dragging are thinned out, the last one always arrives',
      () async {
        final got = <int>[];
        final th = SeekThrottle(
          (d) async => got.add(d.inMilliseconds),
          gap: const Duration(milliseconds: 60),
        );
        for (var i = 1; i <= 40; i++) {
          th.request(Duration(milliseconds: i * 100));
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(got.last, 4000);
        expect(got.length, lessThan(15));
        expect(got.length, greaterThan(1));
        th.dispose();
      },
    );
  });

  group('timeline lanes', () {
    final ranges = <(int, double, double)>[];
    final taps = <int>[];

    Future<void> show(
      WidgetTester t, {
      List<TimelineLane>? lanes,
      String? audio,
    }) async {
      ranges.clear();
      taps.clear();
      await t.pumpWidget(
        _app(
          Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: TrimTimeline(
                  total: 20,
                  start: 0,
                  end: 20,
                  position: ValueNotifier(3),
                  frames: List<Uint8List?>.filled(8, null),
                  audioLabel: audio,
                  lanes:
                      lanes ??
                      const [
                        TimelineLane(
                          kind: LaneKind.text,
                          label: 'Hello',
                          from: 4,
                          to: 10,
                        ),
                        TimelineLane(
                          kind: LaneKind.sticker,
                          label: 'Fire',
                          from: 0,
                          to: -1,
                        ),
                      ],
                  onLaneRange: (i, f, to) => ranges.add((i, f, to)),
                  onLaneTap: taps.add,
                  onRange: (a, b, c) {},
                  onSeek: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump();
    }

    testWidgets('audio, texts and stickers each get a lane', (t) async {
      await show(t, audio: 'Sunrise');
      expect(find.byKey(const ValueKey('audioLane')), findsOneWidget);
      expect(find.byKey(const ValueKey('laneBar0')), findsOneWidget);
      expect(find.byKey(const ValueKey('laneBar1')), findsOneWidget);
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('Fire'), findsOneWidget);
      expect(find.byKey(const ValueKey('playhead')), findsOneWidget);
    });

    testWidgets('a tap selects the lane', (t) async {
      await show(t);
      await t.tap(find.byKey(const ValueKey('laneBar0')));
      expect(taps, contains(0));
    });

    testWidgets('dragging the middle moves it by half seconds', (t) async {
      await show(t);
      // 400 px wide, 16 px handles each side: 368 px for 20 s = 18.4 px per second
      await t.drag(
        find.byKey(const ValueKey('laneBar0')),
        const Offset(110, 0),
      );
      expect(ranges, isNotEmpty);
      final r = ranges.last;
      expect(r.$1, 0);
      expect(r.$3 - r.$2, closeTo(6, 0.001), reason: 'same length');
      expect(r.$2, inInclusiveRange(7, 10.5));
      for (final x in ranges) {
        expect((x.$2 * 2) % 1, 0);
      }
    });

    testWidgets('dragging the right end changes only the end', (t) async {
      await show(t);
      final box = t.getRect(find.byKey(const ValueKey('laneBar0')));
      await t.dragFrom(
        Offset(box.right - 4, box.center.dy),
        const Offset(-92, 0),
      );
      final r = ranges.last;
      expect(r.$2, 4);
      expect(r.$3, inInclusiveRange(5, 7.5));
    });

    testWidgets('dragging the left end changes only the start', (t) async {
      await show(t);
      final box = t.getRect(find.byKey(const ValueKey('laneBar0')));
      await t.dragFrom(
        Offset(box.left + 4, box.center.dy),
        const Offset(92, 0),
      );
      final r = ranges.last;
      expect(r.$3, 10);
      expect(r.$2, inInclusiveRange(7, 9));
    });

    testWidgets('a bar can never leave the video', (t) async {
      await show(t);
      await t.drag(
        find.byKey(const ValueKey('laneBar0')),
        const Offset(-300, 0),
      );
      expect(ranges.last.$2, 0);
      await t.drag(
        find.byKey(const ValueKey('laneBar0')),
        const Offset(300, 0),
      );
      expect(
        ranges.last.$3,
        -1,
        reason: 'reaching the end means until the end',
      );
    });

    testWidgets('many lanes scroll instead of growing', (t) async {
      await show(
        t,
        lanes: [
          for (var i = 0; i < 6; i++)
            TimelineLane(kind: LaneKind.text, label: 'T$i', from: 0, to: -1),
        ],
      );
      final h = t.getSize(find.byKey(const ValueKey('laneList'))).height;
      expect(h, lessThanOrEqualTo(26.0 * 3));
    });
  });

  group('share profile', () {
    testWidgets('QR code, link, username and a Share button', (t) async {
      await t.pumpWidget(
        _app(
          const ShareProfileScreen(
            user: AppUser(uid: 'u', username: 'aryan.s', fullName: 'Aryan'),
          ),
        ),
      );
      await t.pump();
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.text('@aryan.s'), findsOneWidget);
      expect(find.text(profileLinkFor('aryan.s')), findsOneWidget);
      expect(find.byKey(const ValueKey('shareProfileSend')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('buttons', () {
    test('the new words are in every language', () {
      for (final l in kLanguages.where((l) => l.code != 'en')) {
        final lang = Language.instance..value = l.code;
        for (final w in [
          'Continue',
          'Search country',
          'Country',
          'Choose your country',
          'I accept the',
          'Link copied',
          'Mute',
          'Unmute',
          'Pinned',
        ]) {
          expect(lang.translate(w), isNot(w), reason: '${l.code}: $w');
        }
      }
      Language.instance.value = 'en';
    });
  });

  group('moment composer resize', () {
    late File png;
    setUpAll(() {
      png = File('${Directory.systemTemp.path}/v1160_pixel.png')
        ..writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
          ),
        );
    });

    Future<void> open(WidgetTester t) async {
      await t.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(_app(StoryComposerScreen(image: png)));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('storyText')));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const ValueKey('storyTextInput')),
        'Hello you',
      );
      await t.tap(find.byKey(const ValueKey('storyTextDone')));
      await t.pumpAndSettle();
    }

    testWidgets('a tap selects a text: frame, handle and size bar', (t) async {
      await open(t);
      expect(find.byKey(const ValueKey('selectionBar')), findsNothing);
      await t.tap(find.text('Hello you'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('selectedFrame')), findsOneWidget);
      expect(find.byKey(const ValueKey('resizeHandle')), findsOneWidget);
      expect(find.byKey(const ValueKey('selectionBar')), findsOneWidget);

      final before = t
          .getSize(find.byKey(const ValueKey('selectedFrame')))
          .width;
      await t.tap(find.byKey(const ValueKey('sizeUp')));
      await t.pumpAndSettle();
      final bigger = t
          .getSize(find.byKey(const ValueKey('selectedFrame')))
          .width;
      expect(bigger, greaterThan(before));
      await t.tap(find.byKey(const ValueKey('sizeDown')));
      await t.tap(find.byKey(const ValueKey('sizeDown')));
      await t.pumpAndSettle();
      expect(
        t.getSize(find.byKey(const ValueKey('selectedFrame'))).width,
        lessThan(bigger),
      );

      await t.tap(find.byKey(const ValueKey('selDone')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('selectionBar')), findsNothing);
    });

    testWidgets(
      'a sticker is selected when added and can be resized and deleted',
      (t) async {
        await open(t);
        await t.tap(find.byKey(const ValueKey('storySticker')));
        await t.pump(const Duration(seconds: 1));
        await t.pump(const Duration(seconds: 1));
        await t.ensureVisible(find.byKey(const ValueKey('emoji_🔥')));
        await t.tap(find.byKey(const ValueKey('emoji_🔥')));
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('selectionBar')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('selEdit')),
          findsNothing,
          reason: 'stickers have no words',
        );
        await t.tap(find.byKey(const ValueKey('selDelete')));
        await t.pumpAndSettle();
        expect(find.text('🔥'), findsNothing);
      },
    );

    testWidgets('dragging the corner handle makes it bigger', (t) async {
      await open(t);
      await t.tap(find.text('Hello you'));
      await t.pumpAndSettle();
      final before = t
          .getSize(find.byKey(const ValueKey('selectedFrame')))
          .width;
      await t.drag(
        find.byKey(const ValueKey('resizeHandle')),
        const Offset(40, 40),
      );
      await t.pumpAndSettle();
      expect(
        t.getSize(find.byKey(const ValueKey('selectedFrame'))).width,
        greaterThan(before),
      );
    });
  });
}
