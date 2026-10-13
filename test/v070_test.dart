import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:instantgram/core/services/api_client.dart';
import 'package:instantgram/core/services/content_filter.dart';
import 'package:instantgram/core/services/deep_links.dart';
import 'package:instantgram/core/services/video_prep.dart';
import 'package:instantgram/core/services/media_prefetch.dart';
import 'package:instantgram/core/services/music_player.dart';
import 'package:instantgram/core/services/net_quality.dart';
import 'package:instantgram/core/services/uploader.dart';
import 'package:instantgram/core/theme/app_colors.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/core/utils/profile_link.dart';
import 'package:instantgram/features/feed/presentation/widgets/post_card.dart';
import 'package:instantgram/features/post/presentation/post_menu.dart';
import 'package:instantgram/features/profile/data/user_repository.dart';
import 'package:instantgram/features/profile/presentation/edit_profile_screen.dart';
import 'package:instantgram/features/profile/presentation/profile_image_crop.dart';
import 'package:instantgram/features/profile/presentation/share_profile_sheet.dart';
import 'package:instantgram/shared/models/post.dart';
import 'package:instantgram/shared/models/user_profile.dart';
import 'package:instantgram/shared/widgets/avatar.dart';
import 'package:instantgram/shared/widgets/media_view.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:instantgram/shared/widgets/seek_bar.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

Widget _app(Widget child) => MaterialApp(theme: AppTheme.dark, home: child);

Future<void> _frames(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

UserProfile _user([Map<String, dynamic> extra = const {}]) =>
    UserProfile.fromMap('u1', {
      'uid': 'u1',
      'username': 'riya',
      'name': 'Riya',
      ...extra,
    });

/// Video controller that never touches the platform.
class _FakeVideo extends VideoPlayerController {
  _FakeVideo(Duration length)
    : super.networkUrl(Uri.parse('https://x.test/v.mp4')) {
    value = VideoPlayerValue(
      duration: length,
      isInitialized: true,
      size: const Size(1080, 1920),
    );
  }

  final List<Duration> seeks = [];

  @override
  Future<void> seekTo(Duration position) async {
    seeks.add(position);
    value = value.copyWith(position: position);
  }

  @override
  Future<void> play() async => value = value.copyWith(isPlaying: true);

  @override
  Future<void> pause() async => value = value.copyWith(isPlaying: false);

  @override
  // ignore: must_call_super
  Future<void> dispose() async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MusicPlayer.disabled = true;
    kDisableVideoPlayback = true;
    NetImage.disableCache = true;
    MediaPrefetch.disabled = true;
    VideoPool.disabled = true;
    VideoPrep.disabled = true;
    DeepLinks.disabled = true;
    NetQuality.reset();
  });

  // ------------------------------------------------------------ upload
  group('upload', () {
    test('parts cover the whole file, no gaps', () {
      expect(Uploader.planParts(20, 8), [(0, 8), (8, 16), (16, 20)]);
      expect(Uploader.planParts(16, 8), [(0, 8), (8, 16)]);
      expect(Uploader.planParts(0, 8), [(0, 0)]);
      final big = Uploader.planParts(100 * 1024 * 1024 + 5);
      expect(big.first.$1, 0);
      expect(big.last.$2, 100 * 1024 * 1024 + 5);
      for (var i = 1; i < big.length; i++) {
        expect(big[i].$1, big[i - 1].$2);
      }
    });

    test('pool keeps order and limits how many run together', () async {
      var running = 0;
      var most = 0;
      final out = await Uploader.pool<int>(2, [
        for (var i = 0; i < 6; i++)
          () async {
            running++;
            most = most > running ? most : running;
            await Future<void>.delayed(Duration(milliseconds: 5 + (6 - i)));
            running--;
            return i * 10;
          },
      ]);
      expect(out, [0, 10, 20, 30, 40, 50]);
      expect(most, 2);
      expect(await Uploader.pool<int>(3, []), isEmpty);
    });

    test('retry: network errors retried, refused uploads not', () async {
      var calls = 0;
      final v = await Uploader.retry<int>((a) async {
        calls++;
        if (a < 2) throw const SocketException('down');
        return 7;
      });
      expect(v, 7);
      expect(calls, 2);

      calls = 0;
      await expectLater(
        Uploader.retry<int>((_) async {
          calls++;
          throw const UploadRejected('bad key');
        }),
        throwsA(isA<UploadRejected>()),
      );
      expect(calls, 1);

      calls = 0;
      await expectLater(
        Uploader.retry<int>((_) async {
          calls++;
          throw const ApiException('nope', statusCode: 403);
        }),
        throwsA(isA<ApiException>()),
      );
      expect(calls, 1);
    });

    test('put streams the real bytes with true progress', () async {
      // widget tests block real http; this test needs it
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final got = <List<int>>[];
      final lengths = <int>[];
      server.listen((req) async {
        lengths.add(req.contentLength);
        final b = BytesBuilder();
        await for (final c in req) {
          b.add(c);
        }
        got.add(b.takeBytes());
        req.response.headers.set('ETag', '"etag-${got.length}"');
        await req.response.close();
      });
      final dir = await Directory.systemTemp.createTemp('up');
      try {
        final data = Uint8List.fromList(List.generate(300000, (i) => i % 251));
        final file = File('${dir.path}/v.mp4')..writeAsBytesSync(data);
        final url = Uri.parse('http://127.0.0.1:${server.port}/put');
        var progress = 0;
        final etag = await Uploader.put(
          url,
          file,
          headers: {'Content-Type': 'video/mp4'},
          onBytes: (n) => progress += n,
        );
        expect(etag, '"etag-1"');
        expect(progress, data.length);
        expect(lengths.first, data.length);
        expect(got.first, data);

        // a part (bytes 100000..200000)
        final etag2 = await Uploader.put(url, file, start: 100000, end: 200000);
        expect(etag2, '"etag-2"');
        expect(got[1], data.sublist(100000, 200000));
      } finally {
        await server.close(force: true);
        await dir.delete(recursive: true);
        HttpOverrides.global = saved;
      }
    });
  });

  // ------------------------------------------------------------ quality
  group('quality', () {
    const m = MediaItem(
      url: 'https://x/full.mp4',
      key: 'post/u/full.mp4',
      isVideo: true,
      lowUrl: 'https://x/low.mp4',
      lowKey: 'clip/u/low.mp4',
    );

    test('full quality until buffering, then the small copy', () {
      expect(NetQuality.urlFor(m), m.url);
      NetQuality.markSlow();
      expect(NetQuality.slow, isTrue);
      expect(NetQuality.urlFor(m), m.lowUrl);
      // old posts without a small copy keep the original
      expect(
        NetQuality.urlFor(const MediaItem(url: 'https://x/o.mp4')),
        'https://x/o.mp4',
      );
      expect(NetQuality.tileUrl(m), m.lowUrl);
    });

    test('small copy is saved and deleted with the post', () {
      final back = MediaItem.fromMap(m.toMap())!;
      expect(back.lowUrl, m.lowUrl);
      expect(back.lowKey, m.lowKey);
      final p = Post.fromMap('p1', {
        'authorId': 'a',
        'type': 'video',
        'media': [m.toMap()],
        'createdAt': DateTime(2026),
      });
      expect(p.allKeys, containsAll(['post/u/full.mp4', 'clip/u/low.mp4']));
      expect(const MediaItem(url: 'u').toMap().containsKey('lowUrl'), isFalse);
    });

    test('stall watch fires once after buffering a while', () async {
      final c = _FakeVideo(const Duration(seconds: 10));
      var stalls = 0;
      final w = StallWatch(
        c,
        onStall: () => stalls++,
        after: const Duration(milliseconds: 40),
      );
      c.value = c.value.copyWith(isPlaying: true, isBuffering: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      c.value = c.value.copyWith(isBuffering: false); // short hiccup: ok
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(stalls, 0);
      c.value = c.value.copyWith(isBuffering: true);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(stalls, 1);
      c.value = c.value.copyWith(isBuffering: false);
      c.value = c.value.copyWith(isBuffering: true);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(stalls, 1);
      w.dispose();
    });
  });

  // ------------------------------------------------------------ seek bar
  group('seek bar', () {
    testWidgets('tap and drag move the video', (t) async {
      final c = _FakeVideo(const Duration(seconds: 10));
      await t.pumpWidget(
        _app(
          Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: SmoothSeekBar(key: const ValueKey('bar'), controller: c),
              ),
            ),
          ),
        ),
      );
      await _frames(t, 2);
      final box = t.getRect(find.byKey(const ValueKey('bar')));
      await t.tapAt(Offset(box.left + box.width * 0.25, box.center.dy));
      await _frames(t, 2);
      expect(c.seeks, isNotEmpty);
      expect(c.seeks.last.inMilliseconds, closeTo(2500, 150));

      final g = await t.startGesture(
        Offset(box.left + box.width * 0.1, box.center.dy),
      );
      await t.pump(const Duration(milliseconds: 50));
      for (var i = 1; i <= 8; i++) {
        await g.moveTo(
          Offset(box.left + box.width * (0.1 + 0.08 * i), box.center.dy),
        );
        await t.pump(const Duration(milliseconds: 30));
      }
      await g.up();
      await _frames(t, 2);
      expect(c.seeks.last.inMilliseconds, closeTo(7400, 200));
    });

    testWidgets('trimmed clips seek inside the trim', (t) async {
      final c = _FakeVideo(const Duration(seconds: 10));
      await t.pumpWidget(
        _app(
          Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: SmoothSeekBar(
                  key: const ValueKey('bar'),
                  controller: c,
                  startMs: 2000,
                  endMs: 6000,
                ),
              ),
            ),
          ),
        ),
      );
      await _frames(t, 2);
      final box = t.getRect(find.byKey(const ValueKey('bar')));
      await t.tapAt(box.center);
      await _frames(t, 2);
      expect(c.seeks.last.inMilliseconds, closeTo(4000, 150));
    });
  });

  // ------------------------------------------------------------ feed
  group('feed', () {
    testWidgets('counts next to icons, hidden when 0 or turned off', (t) async {
      await t.pumpWidget(
        _app(
          Scaffold(
            body: Row(
              children: [
                ActionCount(
                  key: const ValueKey('a'),
                  icon: const Icon(Icons.favorite_border),
                  count: 1520,
                  hidden: false,
                  onTap: () {},
                ),
                ActionCount(
                  key: const ValueKey('b'),
                  icon: const Icon(Icons.repeat),
                  count: 0,
                  hidden: false,
                  onTap: () {},
                ),
                ActionCount(
                  key: const ValueKey('c'),
                  icon: const Icon(Icons.chat_bubble_outline),
                  count: 99,
                  hidden: true,
                  onTap: () {},
                ),
              ],
            ),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('a')),
          matching: find.text('1.5K'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('b')),
          matching: find.byType(Text),
        ),
        findsNothing,
      );
      expect(find.text('99'), findsNothing);
    });

    testWidgets('⋯ menu has no Share / View account', (t) async {
      ContentFilter.instance.debugSet(me: 'me');
      final post = Post.fromMap('p1', {
        'authorId': 'someone',
        'authorUsername': 'riya',
        'type': 'video',
        'isClip': true,
        'mediaUrl': 'https://x/p1.mp4',
        'createdAt': DateTime(2026, 10, 1),
      });
      await t.pumpWidget(
        _app(
          Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => showPostMenu(ctx, post, showAutoScroll: true),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await _frames(t, 10);
      expect(find.textContaining('Report'), findsOneWidget);
      expect(find.text('Auto scroll'), findsOneWidget);
      expect(find.text('Share'), findsNothing);
      expect(find.textContaining('View @'), findsNothing);
      expect(find.textContaining('View account'), findsNothing);
    });

    test('watched moments keep a faded green ring', () {
      final colors = kSeenRingGradient.colors;
      expect(colors.length, 2);
      for (final c in colors) {
        expect(c.a, lessThan(1));
        expect(c.a, greaterThan(0.1));
      }
      expect(colors.first.withValues(alpha: 1), AppColors.lime);
    });
  });

  // ------------------------------------------------------------ profile links
  group('profile link', () {
    test('username from web link, app link, @name', () {
      expect(usernameFromLink('https://ig.vercel.app/u/riya'), 'riya');
      expect(usernameFromLink('https://ig.vercel.app/u/Riya.K_1/'), 'riya.k_1');
      expect(usernameFromLink('instantgram://u/riya'), 'riya');
      expect(usernameFromLink('  @riya '), 'riya');
      expect(usernameFromLink('https://ig.vercel.app/p/riya'), isNull);
      expect(usernameFromLink('https://ig.vercel.app/u/a'), isNull);
      expect(usernameFromLink('hello world'), isNull);
      expect(usernameFromLink('instantgram://x/riya'), isNull);
    });

    test('profile link goes back to the username', () {
      final link = profileLink('riya');
      expect(link, endsWith('/u/riya'));
      expect(usernameFromLink(link), 'riya');
    });

    test('links: fix https, max 3, old website still shows', () {
      expect(
        ProfileLink.fixUrl('youtube.com/@riya'),
        'https://youtube.com/@riya',
      );
      expect(ProfileLink.fixUrl('http://a.co'), 'http://a.co');
      expect(ProfileLink.fixUrl('hello'), '');
      expect(ProfileLink.fixUrl(''), '');
      final u = _user({
        'links': [
          {'title': 'YouTube', 'url': 'https://youtube.com/@riya'},
          {'title': '', 'url': 'https://riya.dev/'},
          {'title': 'x', 'url': 'https://x.com/r'},
          {'title': 'too many', 'url': 'https://four.com'},
          {'title': 'broken'},
        ],
      });
      expect(u.allLinks.length, 3);
      expect(u.allLinks.first.label, 'YouTube');
      expect(u.allLinks[1].label, 'riya.dev');
      final old = _user({'website': 'https://old.site'});
      expect(old.allLinks.single.url, 'https://old.site');
    });

    test('username rules', () {
      expect(UserRepository.usernameProblem('ab'), isNotEmpty);
      expect(UserRepository.usernameProblem('riya k'), isNotEmpty);
      expect(UserRepository.usernameProblem('riya.k_1'), isEmpty);
      const f = UsernameFormatter();
      final v = f.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(
          text: 'Riya K!',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      expect(v.text, 'riyak');
      expect(v.selection.baseOffset, 5);
    });
  });

  // ------------------------------------------------------------ share sheet
  testWidgets('share profile: QR, copy, share, save, scan', (t) async {
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    await t.pumpWidget(_app(Scaffold(body: ShareProfileSheet(user: _user()))));
    await _frames(t);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-qr')), findsOneWidget);
    for (final k in ['qr-copy', 'qr-share', 'qr-save', 'qr-scan']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(find.text('@riya'), findsWidgets);
    await t.tap(find.byKey(const ValueKey('qr-copy')));
    await _frames(t, 3);
    expect(copied, profileLink('riya'));
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  // ------------------------------------------------------------ crop
  group('crop', () {
    test('sizes: square photo, 5:2 banner', () {
      expect(ProfileImageSpec.photo.width, 1080);
      expect(ProfileImageSpec.photo.height, 1080);
      expect(
        ProfileImageSpec.banner.width / ProfileImageSpec.banner.height,
        kBannerAspect,
      );
      expect(ProfileImageSpec.photo.hint, contains('1080'));
      expect(ProfileImageSpec.banner.hint, contains('1500'));
    });

    test('crop area follows zoom and move', () {
      // 2000x1000 picture in a 300x300 frame: cover => fit 0.3
      final a = cropRect(
        frame: const Size(300, 300),
        imageW: 2000,
        imageH: 1000,
        scale: 1,
        dx: 0,
        dy: 0,
      );
      expect(a.left, 0);
      expect(a.width, closeTo(1000, 0.01));
      expect(a.height, closeTo(1000, 0.01));
      // moved left by 150 screen px = 500 picture px
      final b = cropRect(
        frame: const Size(300, 300),
        imageW: 2000,
        imageH: 1000,
        scale: 1,
        dx: -150,
        dy: 0,
      );
      expect(b.left, closeTo(500, 0.01));
      // zoom 2x => half the area
      final c = cropRect(
        frame: const Size(300, 300),
        imageW: 2000,
        imageH: 1000,
        scale: 2,
        dx: -300,
        dy: -150,
      );
      expect(c.width, closeTo(500, 0.01));
      expect(c.left, closeTo(500, 0.01));
      expect(c.top, closeTo(250, 0.01));
      // can't go outside the picture
      final d = cropRect(
        frame: const Size(300, 300),
        imageW: 2000,
        imageH: 1000,
        scale: 1,
        dx: -99999,
        dy: 500,
      );
      expect(d.right, closeTo(2000, 0.01));
      expect(d.top, 0);
    });

    test('crop + resize gives the right size', () {
      final src = img.Image(width: 3000, height: 2000);
      img.fill(src, color: img.ColorRgb8(200, 30, 30));
      final bytes = Uint8List.fromList(img.encodePng(src));
      final out = img.decodeJpg(
        cropAndResize(
          bytes,
          const Rect.fromLTWH(0, 400, 3000, 1200),
          1500,
          600,
        ),
      )!;
      expect(out.width, 1500);
      expect(out.height, 600);
      // small pictures are not made bigger
      final small = img.decodeJpg(
        cropAndResize(bytes, const Rect.fromLTWH(10, 10, 500, 500), 1080, 1080),
      )!;
      expect(small.width, 500);
    });
  });

  testWidgets('crop screen: Done gives a 1500x600 banner', (t) async {
    final dir = Directory.systemTemp.createTempSync('crop');
    addTearDown(() => dir.deleteSync(recursive: true));
    final src = img.Image(width: 2400, height: 1600);
    img.fill(src, color: img.ColorRgb8(20, 120, 200));
    final file = File('${dir.path}/b.png')
      ..writeAsBytesSync(img.encodePng(src));
    File? result;
    await t.pumpWidget(
      _app(
        Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () async => result = await cropProfileImage(
                ctx,
                file,
                ProfileImageSpec.banner,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    for (
      var i = 0;
      i < 20 && find.byType(InteractiveViewer).evaluate().isEmpty;
      i++
    ) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text(ProfileImageSpec.banner.hint), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('crop-done')));
    for (var i = 0; i < 40 && result == null; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(result, isNotNull);
    final out = img.decodeJpg(result!.readAsBytesSync())!;
    expect(out.width, 1500);
    expect(out.height, 600);
  });

  // ------------------------------------------------------------ edit profile
  group('edit profile', () {
    tearDown(() {
      EditProfileScreen.debugLive = null;
      EditProfileScreen.debugUsernameFree = null;
    });

    testWidgets('size hints, username check, up to 3 links', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.5;
      addTearDown(t.view.reset);
      final me = _user({
        'links': [
          {'title': 'YouTube', 'url': 'https://youtube.com/@riya'},
        ],
      });
      EditProfileScreen.debugLive = (_) => Stream.value(me);
      EditProfileScreen.debugUsernameFree = (n) async => n != 'taken';
      await t.pumpWidget(_app(EditProfileScreen(profile: me)));
      await _frames(t);

      expect(find.text(ProfileImageSpec.banner.hint), findsOneWidget);
      expect(find.text(ProfileImageSpec.photo.hint), findsOneWidget);
      expect(find.byKey(const ValueKey('edit-banner')), findsOneWidget);
      expect(find.byKey(const ValueKey('edit-photo')), findsOneWidget);

      // username
      final field = find.byKey(const ValueKey('edit-username'));
      await t.enterText(field, 'taken');
      await _frames(t, 8);
      expect(find.text('Already taken'), findsOneWidget);
      await t.enterText(field, 'Riya_New');
      await _frames(t, 8);
      expect(find.text('Available'), findsOneWidget);
      expect(
        (t.widget<EditableText>(
          find.descendant(of: field, matching: find.byType(EditableText)),
        )).controller.text,
        'riya_new',
      );
      await t.enterText(field, 'ab');
      await _frames(t, 2);
      expect(find.text('At least 3 characters'), findsOneWidget);

      // links
      expect(find.text('YouTube'), findsOneWidget);
      final add = find.byKey(const ValueKey('add-link'));
      await t.ensureVisible(add);
      await t.tap(add);
      await _frames(t, 2);
      await t.ensureVisible(add);
      await t.tap(add);
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('link-url-2')), findsOneWidget);
      expect(add, findsNothing); // max 3
      await t.ensureVisible(find.byKey(const ValueKey('link-remove-1')));
      await t.tap(find.byKey(const ValueKey('link-remove-1')));
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('link-url-2')), findsNothing);
      expect(find.byKey(const ValueKey('add-link')), findsOneWidget);
    });
  });
}
