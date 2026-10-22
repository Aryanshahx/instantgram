// Epidemic Sound songs in the music picker, the create sheet (choices open
// under Post / Clip / Moment) and our own camera (filters, music, length,
// timer, record in parts).
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/services/api_client.dart';
import 'package:instantgram/core/services/chat_prefs.dart';
import 'package:instantgram/core/services/media_service.dart';
import 'package:instantgram/core/services/music_player.dart';
import 'package:instantgram/core/services/vision_service.dart';
import 'package:instantgram/core/theme/app_theme.dart';
import 'package:instantgram/features/camera/camera_screen.dart';
import 'package:instantgram/features/editor/edit_models.dart';
import 'package:instantgram/features/editor/filters.dart';
import 'package:instantgram/features/music/data/music_repository.dart';
import 'package:instantgram/features/music/presentation/music_picker_sheet.dart';
import 'package:instantgram/features/post/presentation/create_sheet.dart';
import 'package:instantgram/shared/models/music.dart';
import 'package:instantgram/shared/widgets/net_image.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// ------------------------------------------------------------ fake camera

const _back = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);
const _front = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 270,
);

class FakeCamera extends CameraPlatform with MockPlatformInterfaceMixin {
  final List<String> log = [];
  final List<CameraDescription> opened = [];
  Object? createError;
  bool canPause = true;
  int _id = 0;
  final _errors = StreamController<CameraErrorEvent>.broadcast();

  @override
  Future<List<CameraDescription>> availableCameras() async => [_back, _front];

  @override
  Future<int> createCameraWithSettings(
    CameraDescription d,
    MediaSettings? s,
  ) async {
    final e = createError;
    if (e != null) throw e;
    opened.add(d);
    log.add('create ${d.name} sound=${s?.enableAudio}');
    return ++_id;
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {}

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(
        CameraInitializedEvent(
          cameraId,
          1920,
          1080,
          ExposureMode.auto,
          true,
          FocusMode.auto,
          true,
        ),
      );

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errors.stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();

  @override
  Future<void> lockCaptureOrientation(
    int cameraId,
    DeviceOrientation orientation,
  ) async {}

  @override
  Future<double> getMinZoomLevel(int cameraId) async => 1;

  @override
  Future<double> getMaxZoomLevel(int cameraId) async => 8;

  @override
  Future<void> setZoomLevel(int cameraId, double zoom) async =>
      log.add('zoom $zoom');

  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async =>
      log.add('flash ${mode.name}');

  @override
  Future<void> setFocusPoint(int cameraId, Point<double>? point) async =>
      log.add('focus');

  @override
  Future<void> setExposurePoint(int cameraId, Point<double>? point) async {}

  @override
  Widget buildPreview(int cameraId) =>
      const ColoredBox(key: ValueKey('fake-preview'), color: Colors.teal);

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async =>
      log.add('start');

  @override
  Future<void> pauseVideoRecording(int cameraId) async {
    if (!canPause) throw PlatformException(code: 'no-pause');
    log.add('pause');
  }

  @override
  Future<void> resumeVideoRecording(int cameraId) async => log.add('resume');

  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    log.add('stop');
    return XFile('${Directory.systemTemp.path}/ig_fake_video.mp4');
  }

  @override
  Future<XFile> takePicture(int cameraId) async {
    log.add('photo');
    return XFile('${Directory.systemTemp.path}/ig_fake_photo.jpg');
  }

  @override
  Future<void> setDescriptionWhileRecording(CameraDescription d) async =>
      log.add('switch ${d.name}');

  @override
  Future<void> dispose(int cameraId) async => log.add('dispose');

  // v0.0.1 effects: camera frames for ML Kit
  StreamController<CameraImageData>? frames;

  @override
  bool supportsImageStreaming() => true;

  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int cameraId, {
    CameraImageStreamOptions? options,
  }) {
    log.add('stream');
    final c = StreamController<CameraImageData>(
      // a test-zone future, so `await stopImageStream()` ends in fake time
      onCancel: () {
        log.add('stream stop');
        return Future<void>.value();
      },
    );
    frames = c;
    return c.stream;
  }
}

/// One NV21 camera frame (one plane, like CameraX gives).
CameraImageData _nv21(int w, int h) => CameraImageData(
  format: const CameraImageFormat(ImageFormatGroup.nv21, raw: 17),
  width: w,
  height: h,
  planes: [
    CameraImagePlane(
      bytes: Uint8List(w * h * 3 ~/ 2),
      bytesPerRow: w,
      bytesPerPixel: 1,
      width: w,
      height: h,
    ),
  ],
);

// ---------------------------------------------------------------- helpers

Future<void> _frames(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _finish(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 1));
}

Map<String, dynamic> _es(String uuid, {String title = 'Sunny Road'}) => {
  'id': 'es_$uuid',
  'esId': uuid,
  'source': 'epidemic',
  'title': title,
  'artist': 'Ava Low',
  'durationMs': 151000,
  'cover': '',
  'explicit': false,
  'mood': 'Happy',
};

/// Opens our camera from a button and keeps what it gives back.
class _Host {
  CameraResult? result;
  bool done = false;
}

Future<_Host> _openCamera(
  WidgetTester t, {
  ComposeMode mode = ComposeMode.clip,
  bool video = true,
  PickedAudio? audio,
}) async {
  final h = _Host();
  await t.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open'),
              onPressed: () async {
                h.result = await openCamera(
                  ctx,
                  mode: mode,
                  video: video,
                  audio: audio,
                );
                h.done = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.byKey(const ValueKey('open')));
  await _frames(t, 8);
  return h;
}

void main() {
  late FakeCamera cam;

  setUp(() {
    MusicPlayer.disabled = true;
    NetImage.disableCache = true;
    MusicRepository.debugAll = () async => const [];
    MusicRepository.debugTrack = null;
    MusicRepository.instance.debugReset();
    MusicRepository.instance.call = (body, timeout) async =>
        throw const ApiException('Songs are not set up yet', statusCode: 503);
    ChatPrefs.instance.debugSet(ChatPrefsData.empty);
    cam = FakeCamera();
    CameraPlatform.instance = cam;
    CameraScreen.cameras = () async => [_back, _front];
  });

  // ------------------------------------------------------------- songs
  group('Epidemic songs', () {
    test('model + repository read the server answers', () async {
      final calls = <Map<String, dynamic>>[];
      MusicRepository.instance.call = (body, timeout) async {
        calls.add(body);
        switch (body['action']) {
          case 'esHome':
            return {
              'tracks': [_es('a1'), _es('a2'), 'bad'],
              'collections': [
                {'id': 'c1', 'name': 'Trending on TikTok', 'cover': 'x'},
                {'id': '', 'name': 'no id'},
              ],
            };
          case 'esSearch':
            return {
              'tracks': [_es('s1', title: 'Night')],
            };
          case 'esPreview':
            return {'url': 'https://cdn/x.m3u8'};
          case 'esUse':
            return {
              ..._es('a1'),
              'url': 'https://b.t3.tigrisfiles.io/music/es/a1.mp3',
              'startMs': 42000,
            };
          case 'esTracks':
            return {
              'tracks': [_es('z9', title: 'Saved one')],
            };
        }
        return {};
      };
      final repo = MusicRepository.instance;
      final home = await repo.esHome();
      expect(home.tracks.map((t) => t.id), ['es_a1', 'es_a2']);
      expect(home.tracks.first.isEpidemic, isTrue);
      expect(home.tracks.first.esId, 'a1');
      expect(home.tracks.first.url, '');
      expect(home.playlists.map((p) => p.name), ['Trending on TikTok']);
      await repo.esHome(); // kept 10 minutes
      expect(calls.where((c) => c['action'] == 'esHome').length, 1);
      expect((await repo.esSearch('  night ')).single.title, 'Night');
      expect(calls.last['term'], 'night');
      expect(await repo.esSearch(' '), isEmpty);
      expect(await repo.esPreview('a1'), 'https://cdn/x.m3u8');
      await repo.esPreview('a1'); // kept
      expect(calls.where((c) => c['action'] == 'esPreview').length, 1);
      final used = await repo.esUse(home.tracks.first);
      expect(used.url, endsWith('/music/es/a1.mp3'));
      expect(used.startMs, 42000);
      expect(calls.last, {'action': 'esUse', 'id': 'a1'});
      // saved Epidemic songs nobody used yet come from Epidemic
      MusicRepository.debugTrack = (id) async => id == 'o_1'
          ? MusicTrack.fromMap(id, {
              'source': 'original',
              'title': 'Mine',
              'url': 'https://x/o.mp3',
            })
          : null;
      final saved = await repo.saved(['o_1', 'es_z9']);
      expect(saved.map((t) => t.id), ['es_z9', 'o_1']);
      expect(calls.last, {
        'action': 'esTracks',
        'ids': ['es_z9'],
      });
    });

    testWidgets('picker: Trending songs, playlists, search, Use', (t) async {
      final calls = <String>[];
      var failUse = true;
      MusicRepository.instance.call = (body, timeout) async {
        calls.add('${body['action']}');
        switch (body['action']) {
          case 'esHome':
            return {
              'tracks': [_es('a1'), _es('a2', title: 'Blue Hour')],
              'collections': [
                {'id': 'c1', 'name': 'Trending on TikTok'},
              ],
            };
          case 'esCollection':
            return {
              'name': 'Trending on TikTok',
              'tracks': [_es('t1', title: 'Viral Beat')],
            };
          case 'esSearch':
            return {
              'tracks': [_es('s1', title: 'Sunny Night')],
            };
          case 'esUse':
            await Future<void>.delayed(const Duration(milliseconds: 150));
            if (failUse) {
              throw const ApiException("This song can't be used here.");
            }
            return {
              ..._es('s1', title: 'Sunny Night'),
              'url': 'https://b.t3.tigrisfiles.io/music/es/s1.mp3',
              'startMs': 30000,
            };
        }
        return {};
      };
      MusicRepository.debugAll = () async => [
        MusicTrack.fromMap('o_p1', {
          'source': 'original',
          'title': 'Sunny day',
          'artist': '@kay',
          'url': 'https://x/o.mp3',
          'uses': 3,
        }),
      ];
      late BuildContext ctx;
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (c) {
                ctx = c;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      PickedAudio? got;
      unawaited(showMusicPicker(ctx).then((a) => got = a));
      await _frames(t);
      // Trending = Epidemic popular songs + playlists
      expect(find.byKey(const ValueKey('track-es_a1')), findsOneWidget);
      expect(find.byKey(const ValueKey('es-credit')), findsOneWidget);
      expect(find.text('Music by Epidemic Sound'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('es-chip-c1')));
      await _frames(t);
      expect(find.byKey(const ValueKey('track-es_t1')), findsOneWidget);
      expect(find.byKey(const ValueKey('track-es_a1')), findsNothing);
      await t.tap(find.byKey(const ValueKey('es-chip-popular')));
      await _frames(t);
      expect(find.byKey(const ValueKey('track-es_a1')), findsOneWidget);
      // search: Epidemic songs first, then audios people made
      await t.enterText(find.byKey(const ValueKey('audio-search')), 'sunny');
      await _frames(t, 5);
      final rows = t
          .widgetList<TrackRow>(
            find.byWidgetPredicate((w) => w is TrackRow, skipOffstage: false),
          )
          .map((r) => r.track.id)
          .toList();
      expect(rows, ['es_s1', 'o_p1']);
      // a song that can't be used: message, the picker stays
      await t.tap(find.byKey(const ValueKey('track-use-es_s1')));
      await t.pump();
      expect(find.byKey(const ValueKey('es-getting')), findsOneWidget);
      await _frames(t, 3);
      expect(find.text("This song can't be used here."), findsOneWidget);
      expect(find.byKey(const ValueKey('es-getting')), findsNothing);
      expect(got, isNull);
      // now it works: saved copy + best part
      failUse = false;
      await t.tap(find.byKey(const ValueKey('track-use-es_s1')));
      await _frames(t);
      expect(got?.musicId, 'es_s1');
      expect(got?.url, 'https://b.t3.tigrisfiles.io/music/es/s1.mp3');
      expect(got?.startMs, 30000);
      expect(got?.name, 'Sunny Night · Ava Low');
      expect(calls.where((c) => c == 'esUse').length, 2);
      await _finish(t);
    });

    testWidgets('picker: Epidemic down -> Original still works', (t) async {
      MusicRepository.instance.call = (body, timeout) async =>
          throw const ApiException('busy', statusCode: 502);
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: MusicPickerSheet()),
        ),
      );
      await _frames(t);
      expect(
        find.byKey(const ValueKey('audio-trending-retry')),
        findsOneWidget,
      );
      await t.tap(find.byKey(const ValueKey('music-tab-original')));
      await _frames(t);
      expect(find.text('No audios yet'), findsOneWidget);
      await _finish(t);
    });
  });

  // ------------------------------------------------------- create sheet
  group('create sheet', () {
    testWidgets('choices open under Post / Clip / Moment', (t) async {
      late BuildContext ctx;
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (c) {
                ctx = c;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      unawaited(showCreateSheet(ctx));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('create-photo-gallery')), findsNothing);
      await t.tap(find.byKey(const ValueKey('create-photo')));
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('create-photo-gallery')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('create-photo-photo')), findsOneWidget);
      expect(find.byKey(const ValueKey('create-photo-video')), findsOneWidget);
      // the choices are right under "Post", above "Clip"
      final chipY = t
          .getTopLeft(find.byKey(const ValueKey('create-photo-gallery')))
          .dy;
      final postY = t.getTopLeft(find.text('Post')).dy;
      final clipY = t.getTopLeft(find.text('Clip')).dy;
      expect(chipY, greaterThan(postY));
      expect(chipY, lessThan(clipY));
      // open Clip: Post closes
      await t.tap(find.byKey(const ValueKey('create-clip')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('create-photo-gallery')), findsNothing);
      expect(find.byKey(const ValueKey('create-clip-video')), findsOneWidget);
      // Record video opens our camera (no second sheet)
      await t.tap(find.byKey(const ValueKey('create-clip-video')));
      await _frames(t, 10);
      expect(find.byKey(const ValueKey('camera-screen')), findsOneWidget);
      expect(find.byKey(const ValueKey('fake-preview')), findsOneWidget);
      expect(find.byKey(const ValueKey('pick-gallery')), findsNothing);
      await t.tap(find.byKey(const ValueKey('camera-close')));
      await _frames(t);
      expect(find.byKey(const ValueKey('camera-screen')), findsNothing);
      await _finish(t);
    });

    testWidgets('replies still ask where from', (t) async {
      late BuildContext ctx;
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (c) {
                ctx = c;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      unawaited(startCompose(ctx, ComposeMode.clip));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('pick-gallery')), findsOneWidget);
      expect(find.text('Filters, music, length and more'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('pick-photo')));
      await _frames(t, 10);
      expect(find.byKey(const ValueKey('camera-screen')), findsOneWidget);
      expect(find.text('PHOTO'), findsOneWidget);
      await _finish(t);
    });
  });

  // ------------------------------------------------------------- camera
  group('camera', () {
    testWidgets('record in parts, music, filter -> video', (t) async {
      final song = PickedAudio.online(
        url: 'https://b.t3.tigrisfiles.io/music/es/s1.mp3',
        name: 'Sunny Night · Ava Low',
        musicId: 'es_s1',
        startMs: 30000,
      );
      final h = await _openCamera(t, audio: song);
      expect(cam.log.first, 'create back sound=true');
      expect(find.text('Sunny Night · Ava Low'), findsOneWidget);
      // length: 90 -> 15 -> 30 ... (clips up to 90 s)
      expect(find.text('90'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('camera-length')));
      await t.pump();
      expect(find.text('15'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('camera-length')));
      await t.pump();
      expect(find.text('30'), findsOneWidget);
      // filters
      await t.tap(find.byKey(const ValueKey('camera-filters')));
      await t.pump();
      expect(find.byKey(const ValueKey('camera-filter-strip')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('camera-filter-2')));
      await t.pump();
      final name = t.widget<Text>(
        find.byKey(const ValueKey('camera-filter-name')),
      );
      expect(name.data, kFilterPresets[2].name);
      await t.pump(const Duration(seconds: 1));
      // tap = start
      await t.tap(find.byKey(const ValueKey('camera-record')));
      await _frames(t, 2);
      expect(cam.log, contains('start'));
      expect(find.byKey(const ValueKey('camera-next')), findsOneWidget);
      expect(find.byKey(const ValueKey('camera-retake')), findsOneWidget);
      expect(find.byKey(const ValueKey('camera-gallery')), findsNothing);
      expect(find.text('PHOTO'), findsNothing);
      await t.pump(const Duration(seconds: 2));
      // tap = pause, tap = film more
      await t.tap(find.byKey(const ValueKey('camera-record')));
      await _frames(t, 2);
      expect(cam.log, contains('pause'));
      expect(find.text('Paused · tap to film more'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('camera-record')));
      await _frames(t, 2);
      expect(cam.log, contains('resume'));
      // flip while filming keeps the same video
      await t.tap(find.byKey(const ValueKey('camera-flip')));
      await _frames(t, 2);
      expect(cam.log, contains('switch front'));
      await t.pump(const Duration(seconds: 1));
      await t.tap(find.byKey(const ValueKey('camera-next')));
      await _frames(t, 4);
      expect(cam.log, contains('stop'));
      expect(h.done, isTrue);
      final m = h.result!.media.single;
      expect(m.isVideo, isTrue);
      expect(m.filterPreset, 2);
      expect(m.muted, isTrue, reason: 'music chosen: own sound starts off');
      expect(h.result!.audio?.musicId, 'es_s1');
      await _finish(t);
    });

    testWidgets('stops by itself at the length; hold to record', (t) async {
      final h = await _openCamera(t, mode: ComposeMode.story);
      // moments: 60 s max, so 15 / 30 / 60
      expect(find.text('60'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('camera-length')));
      await t.pump();
      expect(find.text('15'), findsOneWidget);
      // hold = film while held
      final g = await t.startGesture(
        t.getCenter(find.byKey(const ValueKey('camera-record'))),
      );
      await t.pump(const Duration(milliseconds: 700));
      await _frames(t, 2);
      expect(cam.log, contains('start'));
      await t.pump(const Duration(seconds: 2));
      await g.up();
      await _frames(t, 2);
      expect(cam.log, contains('pause'));
      expect(h.done, isFalse);
      // continue: stops at 15 s by itself
      await t.tap(find.byKey(const ValueKey('camera-record')));
      await _frames(t, 2);
      for (var i = 0; i < 150 && !h.done; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(h.done, isTrue);
      expect(cam.log.last, anyOf('stop', 'dispose'));
      expect(h.result!.media.single.isVideo, isTrue);
      expect(h.result!.media.single.muted, isFalse);
      await _finish(t);
    });

    testWidgets('photo: timer counts down, then takes it', (t) async {
      final h = await _openCamera(t, video: false);
      expect(find.byKey(const ValueKey('camera-length')), findsNothing);
      // flash: off -> auto
      await t.tap(find.byKey(const ValueKey('camera-flash')));
      await _frames(t, 1);
      expect(cam.log, contains('flash auto'));
      await t.tap(find.byKey(const ValueKey('camera-timer')));
      await t.pump();
      expect(find.text('3s'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('camera-record')));
      await t.pump();
      expect(find.byKey(const ValueKey('camera-countdown')), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(cam.log, isNot(contains('photo')));
      await t.pump(const Duration(seconds: 1));
      expect(find.text('2'), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
      await _frames(t, 3);
      expect(cam.log, contains('photo'));
      expect(h.result!.media.single.isVideo, isFalse);
      await _finish(t);
    });

    testWidgets('start over deletes what was filmed', (t) async {
      final h = await _openCamera(t);
      await t.tap(find.byKey(const ValueKey('camera-record')));
      await _frames(t, 2);
      await t.pump(const Duration(seconds: 1));
      await t.tap(find.byKey(const ValueKey('camera-retake')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('camera-retake-yes')));
      await _frames(t, 3);
      expect(cam.log, contains('stop'));
      expect(h.done, isFalse);
      expect(find.byKey(const ValueKey('camera-gallery')), findsOneWidget);
      expect(find.text('VIDEO'), findsOneWidget);
      await _finish(t);
    });

    testWidgets('phone without pause: keeps the video', (t) async {
      cam.canPause = false;
      final h = await _openCamera(t);
      await t.tap(find.byKey(const ValueKey('camera-record')));
      await _frames(t, 2);
      await t.pump(const Duration(seconds: 1));
      await t.tap(find.byKey(const ValueKey('camera-record')));
      await _frames(t, 4);
      expect(h.done, isTrue);
      expect(h.result!.media.single.isVideo, isTrue);
      await _finish(t);
    });

    testWidgets('no camera / not allowed -> message + phone camera', (t) async {
      CameraScreen.cameras = () async => const [];
      await _openCamera(t);
      expect(find.byKey(const ValueKey('camera-error')), findsOneWidget);
      expect(find.text('No camera found on this phone.'), findsOneWidget);
      expect(find.byKey(const ValueKey('camera-system')), findsOneWidget);
      await _finish(t);

      CameraScreen.cameras = () async => [_back];
      cam.createError = PlatformException(code: 'CameraAccessDenied');
      await _openCamera(t);
      expect(
        find.text('Allow the camera in your phone settings to film here.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('camera-system')), findsOneWidget);
      await _finish(t);
    });

    testWidgets('no microphone allowed -> films without sound', (t) async {
      var first = true;
      final real = cam;
      CameraPlatform.instance = _NoMicCamera(real, () {
        final f = first;
        first = false;
        return f;
      });
      await _openCamera(t);
      expect(find.byKey(const ValueKey('fake-preview')), findsOneWidget);
      expect(real.log.first, 'create back sound=false');
      await _finish(t);
    });

    testWidgets('Add audio opens the music picker', (t) async {
      await _openCamera(t);
      await t.tap(find.byKey(const ValueKey('camera-add-audio')));
      await _frames(t);
      expect(find.byType(MusicPickerSheet), findsOneWidget);
      await _finish(t);
    });

    test('camera filter + muted go into the editor', () {
      final item = EditItem(
        PickedMedia(File('v.mp4'), isVideo: true, filterPreset: 3, muted: true),
        mode: ComposeMode.clip,
      );
      expect(item.color.preset, 3);
      expect(item.muted, isTrue);
      final plain = EditItem(
        PickedMedia(File('p.jpg'), isVideo: false),
        mode: ComposeMode.photo,
      );
      expect(plain.color.preset, 0);
      expect(plain.muted, isFalse);
    });
  });

  // ------------------------------------------------------- v0.0.1 effects
  group('camera effects', () {
    late List<MethodCall> calls;
    late Completer<bool> install;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      calls = [];
      VisionService.instance.debugReset();
      messenger.setMockMethodCallHandler(VisionService.channel, (c) async {
        calls.add(c);
        switch (c.method) {
          case 'status':
            return false;
          case 'install':
            return install.future;
          case 'analyze':
            return {
              'w': 240,
              'h': 320,
              'faces': [
                {
                  'lx': 0.4,
                  'ly': 0.4,
                  'rx': 0.6,
                  'ry': 0.4,
                  'l': 0.3,
                  't': 0.3,
                  'r': 0.7,
                  'b': 0.7,
                },
              ],
            };
        }
        return null;
      });
    });
    tearDown(() {
      messenger.setMockMethodCallHandler(VisionService.channel, null);
      VisionService.instance.debugReset();
    });

    testWidgets('download once, then glasses follow the face', (t) async {
      // made inside the test (fake time) so it can finish here
      install = Completer<bool>();
      await _openCamera(t);
      await t.tap(find.byKey(const ValueKey('camera-effects')));
      await _frames(t, 2);
      // first time: the face model is downloaded (not in the APK)
      expect(
        find.byKey(const ValueKey('camera-fx-downloading')),
        findsOneWidget,
      );
      expect(calls.map((c) => c.method), contains('install'));
      expect(cam.log, isNot(contains('stream')));
      install.complete(true);
      await _frames(t, 3);
      expect(find.byKey(const ValueKey('camera-fx-downloading')), findsNothing);
      expect(find.byKey(const ValueKey('camera-fx-strip')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('camera-fx-sunglasses')));
      await _frames(t, 2);
      expect(cam.log, contains('stream'));
      cam.frames!.add(_nv21(640, 480));
      await _frames(t, 3);
      final a = calls.lastWhere((c) => c.method == 'analyze').arguments as Map;
      // made small before it goes to ML Kit
      expect(a['w'], 320);
      expect(a['h'], 240);
      expect((a['bytes'] as Uint8List).length, 320 * 240 * 3 ~/ 2);
      expect(a['rotation'], 90);
      expect(a['mirror'], isFalse);
      expect(a['face'], isTrue);
      expect(a['segment'], isFalse);
      expect(find.byKey(const ValueKey('camera-face-fx')), findsOneWidget);
      // v0.0.1 fix: background effects are there in video mode too
      expect(find.byKey(const ValueKey('camera-fx-green')), findsOneWidget);
      expect(
        find.text('Green screen works for photos. Switch to Photo.'),
        findsNothing,
      );
      // no effect -> camera frames stop, glasses gone
      await t.tap(find.byKey(const ValueKey('camera-fx-none')));
      await _frames(t, 2);
      expect(cam.log, contains('stream stop'));
      expect(find.byKey(const ValueKey('camera-face-fx')), findsNothing);
      // second time: no download
      final installs = calls.where((c) => c.method == 'install').length;
      await t.tap(find.byKey(const ValueKey('camera-effects')));
      await _frames(t, 2);
      await t.tap(find.byKey(const ValueKey('camera-effects')));
      await _frames(t, 2);
      expect(calls.where((c) => c.method == 'install').length, installs);
      expect(find.byKey(const ValueKey('camera-fx-strip')), findsOneWidget);
      await _finish(t);
    });

    testWidgets('flip (not filming): quick turn, same camera, effects go on', (
      t,
    ) async {
      install = Completer<bool>();
      await _openCamera(t);
      await t.tap(find.byKey(const ValueKey('camera-effects')));
      await _frames(t, 2);
      install.complete(true);
      await _frames(t, 3);
      await t.tap(find.byKey(const ValueKey('camera-fx-sunglasses')));
      await _frames(t, 2);
      expect(cam.log, contains('stream'));
      cam.log.clear();
      await t.tap(find.byKey(const ValueKey('camera-flip')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));
      // a quick turn instead of a black loading screen
      expect(find.byKey(const ValueKey('camera-flipping')), findsOneWidget);
      expect(find.byKey(const ValueKey('camera-starting')), findsNothing);
      await _frames(t, 6);
      expect(find.byKey(const ValueKey('camera-flipping')), findsNothing);
      expect(find.byKey(const ValueKey('fake-preview')), findsWidgets);
      final log = cam.log;
      final create = log.indexWhere((l) => l.startsWith('create front'));
      expect(create, greaterThan(0), reason: log.join(', '));
      // frames stop, the lens changes, frames start again
      expect(log.indexOf('stream stop'), lessThan(log.indexOf('dispose')));
      expect(log.indexOf('dispose'), lessThan(create));
      expect(log.lastIndexOf('stream'), greaterThan(create));
      cam.frames!.add(_nv21(640, 480));
      await _frames(t, 3);
      final a = calls.lastWhere((c) => c.method == 'analyze').arguments as Map;
      expect(a['mirror'], isTrue, reason: 'front camera now');
      // and back again
      await t.tap(find.byKey(const ValueKey('camera-flip')));
      await _frames(t, 6);
      expect(cam.log.where((l) => l.startsWith('create back')), isNotEmpty);
      await _finish(t);
    });

    testWidgets('video: blur background live + put into the video', (t) async {
      messenger.setMockMethodCallHandler(VisionService.channel, (c) async {
        calls.add(c);
        switch (c.method) {
          case 'status':
            return true; // models ready
          case 'analyze':
            return {'w': 240, 'h': 320};
          case 'fxVideo':
            return {'path': '/tmp/fx_out.mp4', 'cancelled': false};
        }
        return null;
      });
      // a real phone screen (the 800x600 test screen is too small)
      t.view.physicalSize = const Size(1080, 2340);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final h = await _openCamera(t);
      await t.tap(find.byKey(const ValueKey('camera-effects')));
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('camera-fx-bg-blur')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('camera-fx-bg-blur')));
      await _frames(t, 2);
      expect(find.byKey(const ValueKey('camera-bg-blur')), findsOneWidget);
      cam.frames!.add(_nv21(640, 480));
      await _frames(t, 2);
      final a = calls.lastWhere((c) => c.method == 'analyze').arguments as Map;
      expect(a['segment'], isTrue);
      expect(a['face'], isFalse);
      // filming keeps the effect on screen, then it goes INTO the video
      await t.tap(find.byKey(const ValueKey('camera-record')));
      await _frames(t, 2);
      await t.pump(const Duration(seconds: 1));
      await t.tap(find.byKey(const ValueKey('camera-next')));
      await _frames(t, 4);
      final fx = calls.lastWhere((c) => c.method == 'fxVideo').arguments as Map;
      expect(fx['mode'], 'blur');
      expect(fx['path'], endsWith('ig_fake_video.mp4'));
      expect(fx.containsKey('bg'), isFalse);
      expect(h.done, isTrue);
      expect(h.result!.media.single.file.path, '/tmp/fx_out.mp4');
      expect(h.result!.media.single.isVideo, isTrue);
      await _finish(t);
    });

    testWidgets('download fails -> message, no effects', (t) async {
      install = Completer<bool>();
      await _openCamera(t);
      await t.tap(find.byKey(const ValueKey('camera-effects')));
      await _frames(t, 2);
      install.completeError(PlatformException(code: 'x', message: 'net'));
      await _frames(t, 3);
      expect(find.byKey(const ValueKey('camera-fx-downloading')), findsNothing);
      expect(find.byKey(const ValueKey('camera-fx-strip')), findsNothing);
      expect(find.byType(SnackBar), findsOneWidget);
      await _finish(t);
    });
  });
}

/// First camera start says "microphone not allowed".
class _NoMicCamera extends FakeCamera {
  _NoMicCamera(this.real, this.failNow);
  final FakeCamera real;
  final bool Function() failNow;

  @override
  Future<int> createCameraWithSettings(
    CameraDescription d,
    MediaSettings? s,
  ) async {
    if (s?.enableAudio == true && failNow()) {
      throw PlatformException(code: 'AudioAccessDenied');
    }
    return real.createCameraWithSettings(d, s);
  }
}
