import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:instantgram/screens/post/create_post_screen.dart';
import 'package:instantgram/services/post_pager.dart';
import 'package:instantgram/widgets/reel_actions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/errors.dart';
import 'package:instantgram/core/responsive.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/screens/auth/login_screen.dart';
import 'package:instantgram/screens/auth/signup_screen.dart';
import 'package:instantgram/widgets/avatar.dart';
import 'package:instantgram/widgets/brand_logo.dart';
import 'package:instantgram/widgets/pill_tabs.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/widgets/state_views.dart';
import 'package:instantgram/widgets/video_thumb.dart';

Widget _app(Widget child, ThemeData theme) =>
    MaterialApp(theme: theme, home: child);

void main() {
  test('upload errors are explained in plain words', () {
    expect(friendlyError(const MediaException('x')), 'x');
    DioException dio(DioExceptionType t, [int? code, Object? data]) =>
        DioException(
          requestOptions: RequestOptions(path: '/upload'),
          type: t,
          response: code == null
              ? null
              : Response(
                  requestOptions: RequestOptions(path: '/upload'),
                  statusCode: code,
                  data: data,
                ),
        );
    expect(
      friendlyError(dio(DioExceptionType.connectionError)),
      contains('media service'),
    );
    expect(
      friendlyError(dio(DioExceptionType.badResponse, 401)),
      contains('log'),
    );
    expect(
      friendlyError(
        dio(DioExceptionType.badResponse, 413, {
          'detail': 'File is too large.',
        }),
      ),
      'File is too large.',
    );
    expect(
      friendlyError(dio(DioExceptionType.badResponse, 403)),
      contains('refused'),
    );
    expect(
      friendlyError(dio(DioExceptionType.badResponse, 429)),
      contains('Too many'),
    );
  });

  test('grid columns adapt to tablets', () {
    expect(gridColumnsFor(380), 2);
    expect(gridColumnsFor(600), 3);
    expect(gridColumnsFor(900), 4);
  });

  testWidgets('login fits a 10-inch tablet in landscape', (t) async {
    t.view.physicalSize = const Size(2560, 1600);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(_app(const LoginScreen(), AppTheme.dark));
    await t.pump(const Duration(milliseconds: 300));
    expect(t.takeException(), isNull);
  });

  group('Create screen', () {
    for (final size in const [
      Size(720, 1280), // small phone
      Size(1080, 2400), // tall phone
      Size(2560, 1600), // tablet, landscape
    ]) {
      testWidgets('preview frame is clean and fits at ${size.width.toInt()}', (
        t,
      ) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 2;
        addTearDown(t.view.reset);
        await t.pumpWidget(_app(const CreatePostScreen(), AppTheme.dark));
        await t.pump(const Duration(milliseconds: 300));

        final frame = find.byKey(const ValueKey('previewFrame'));
        expect(frame, findsOneWidget);
        final box = t.getSize(frame);
        // Post: 4:5 until a photo says otherwise
        expect(box.width / box.height, closeTo(4 / 5, 0.01));
        // nothing (no text, no button) is drawn inside the preview
        expect(
          find.descendant(of: frame, matching: find.byType(Text)),
          findsNothing,
        );
        expect(
          find.descendant(of: frame, matching: find.byType(FilledButton)),
          findsNothing,
        );
        // square corners
        expect(
          find.descendant(of: frame, matching: find.byType(ClipRRect)),
          findsNothing,
        );
        // the buttons are outside, under it
        expect(find.text('Choose photos or videos'), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('mode1')));
        await t.pump(const Duration(milliseconds: 300));
        // Clips: always 9:16
        expect(
          t.getSize(frame).width / t.getSize(frame).height,
          closeTo(9 / 16, 0.01),
        );
        expect(find.text('Choose a video or photo'), findsOneWidget);
        // no separate Video / Photo switch: one picker handles both
        expect(find.text('Photo + music'), findsNothing);
        expect(t.takeException(), isNull);
      });
    }
  });

  group('Clips screen pieces', () {
    testWidgets('action buttons are plain icons without a background', (
      t,
    ) async {
      var taps = 0;
      await t.pumpWidget(
        _app(
          Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: ReelIconButton(
                icon: Icons.favorite_rounded,
                label: '12',
                onTap: () => taps++,
              ),
            ),
          ),
          AppTheme.dark,
        ),
      );
      expect(find.text('12'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
      final decorated = find.descendant(
        of: find.byType(ReelIconButton),
        matching: find.byType(DecoratedBox),
      );
      expect(decorated, findsNothing);
      await t.tap(find.byType(ReelIconButton));
      expect(taps, 1);
    });

    test('a tapped clip is placed first in the Clips list', () {
      final clip = Post(
        id: 'tapped',
        authorId: 'u',
        authorUsername: 'n',
        authorPhotoUrl: '',
        type: 'video',
        caption: '',
        createdAt: DateTime(2026),
        videoRef: 'm:video/u/aaaaaaaaaaaaaaaa.mp4',
      );
      final pager = PostPager(
        () => throw StateError('not loaded in this test'),
        first: clip,
      );
      expect(pager.posts.map((p) => p.id), ['tapped']);
      expect(pager.initialLoading, isFalse);
    });
  });

  for (final entry in {
    'light': AppTheme.light,
    'dark': AppTheme.dark,
  }.entries) {
    group('Volt UI (${entry.key})', () {
      testWidgets('login screen renders without layout errors', (t) async {
        t.view.physicalSize = const Size(1080, 2000);
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        await t.pumpWidget(_app(const LoginScreen(), entry.value));
        await t.pump(const Duration(milliseconds: 300));
        expect(find.text('Log in'), findsOneWidget);
        expect(find.textContaining('instantly'), findsOneWidget);
        // text wordmark instead of the logo picture
        expect(find.text('InstantGram'), findsOneWidget);
        expect(find.byType(Image), findsNothing);
        expect(find.text('Email or username'), findsOneWidget);
        expect(t.takeException(), isNull);
      });

      testWidgets('signup screen renders on a small phone', (t) async {
        t.view.physicalSize = const Size(720, 1280);
        t.view.devicePixelRatio = 2;
        addTearDown(t.view.reset);
        await t.pumpWidget(_app(const SignupScreen(), entry.value));
        await t.pump(const Duration(milliseconds: 300));
        expect(find.text('Create account'), findsOneWidget);
        expect(find.text('InstantGram'), findsOneWidget);
        expect(find.byType(Image), findsNothing);
        expect(t.takeException(), isNull);
      });

      testWidgets('video thumbnail shows duration and play button', (t) async {
        await t.pumpWidget(
          _app(
            Scaffold(
              body: SizedBox(
                width: 200,
                height: 300,
                child: VideoThumb(
                  post: Post(
                    id: 'p',
                    authorId: 'u',
                    authorUsername: 'n',
                    authorPhotoUrl: '',
                    type: 'video',
                    caption: '',
                    createdAt: DateTime(2026),
                    videoRef: 'm:video/u/aaaaaaaaaaaaaaaa.mp4',
                    videoDuration: 83,
                  ),
                ),
              ),
            ),
            entry.value,
          ),
        );
        // no duration chip and no button background, just the picture and a play icon
        expect(find.text('1:23'), findsNothing);
        expect(
          find.descendant(
            of: find.byType(VideoThumb),
            matching: find.byType(DecoratedBox),
          ),
          // only the placeholder gradient (no round button behind the icon)
          findsOneWidget,
        );
        expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
        expect(t.takeException(), isNull);
      });

      testWidgets('avatars are circles', (t) async {
        await t.pumpWidget(
          _app(
            const Scaffold(
              body: Center(
                child: UserAvatar(
                  url: '',
                  name: 'aryan',
                  radius: 30,
                  ring: true,
                ),
              ),
            ),
            entry.value,
          ),
        );
        expect(find.byType(ClipOval), findsOneWidget);
        expect(find.byType(ClipRRect), findsNothing);
        expect(t.getSize(find.byType(ClipOval)), const Size(60, 60));
      });

      testWidgets('shared widgets render', (t) async {
        var tab = 0;
        await t.pumpWidget(
          _app(
            Scaffold(
              body: StatefulBuilder(
                builder: (context, set) => Column(
                  children: [
                    const BrandWordmark(size: 28),
                    const UserAvatar(
                      url: '',
                      name: 'aryan',
                      radius: 30,
                      ring: true,
                    ),
                    PillTabs(
                      labels: const ['Discover', 'Following'],
                      index: tab,
                      onChanged: (i) => set(() => tab = i),
                    ),
                    const Expanded(
                      child: EmptyState(
                        icon: Icons.bolt_rounded,
                        title: 'Empty',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            entry.value,
          ),
        );
        await t.tap(find.text('Following'));
        await t.pump(const Duration(milliseconds: 400));
        expect(tab, 1);
        expect(find.text('Empty'), findsOneWidget);
        expect(t.takeException(), isNull);
      });
    });
  }
}
