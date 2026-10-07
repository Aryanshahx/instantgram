import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/errors.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/music.dart';
import 'package:instantgram/services/audio_merger.dart';
import 'package:instantgram/services/device_audio.dart';
import 'package:instantgram/widgets/music_widgets.dart';

Future<void> _open(WidgetTester tester, {MusicTrack? current}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: Builder(
        builder: (c) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => pickMusic(c, current: current),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('v1181');
    DeviceAudio.pickBackend = null;
    DeviceAudio.uploadBackend = null;
    AudioMerger.convertBackend = null;
  });
  tearDown(() {
    DeviceAudio.pickBackend = null;
    DeviceAudio.uploadBackend = null;
    AudioMerger.convertBackend = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('a song from the phone', () {
    test('a picked song is local, an uploaded one has a link', () {
      final a = MusicTrack.device(
        path: '/x/a.mp4',
        title: ' Morning ',
        seconds: 42,
      );
      expect(a.id, kDeviceLocalId);
      expect(a.isDevice, isTrue);
      expect(a.isLocal, isTrue);
      expect(a.remote, isTrue);
      expect(a.title, 'Morning');
      expect(a.uploadedUrl, '');
      expect(deviceMusicRef(a.id), '');

      final b = MusicTrack.uploaded(key: 'video/u1/abc.mp4', title: 'Morning');
      expect(b.id, 'my:video/u1/abc.mp4');
      expect(b.isLocal, isFalse);
      expect(b.isDevice, isTrue);
      expect(b.uploadedUrl, endsWith('/video/u1/abc.mp4'));
      expect(deviceMusicRef(b.id), 'm:video/u1/abc.mp4');
      expect(deviceMusicRef('it:5'), '');
      expect(deviceMusicRef(''), '');
    });

    test('an empty name gets a default', () {
      expect(MusicTrack.device(path: 'p', title: '  ').title, 'My sound');
    });

    test('a post made by someone else shows the name of the sound', () {
      rememberMusic('my:video/u9/zzz.mp4', 'Their beat', '');
      final t = musicById('my:video/u9/zzz.mp4');
      expect(t, isNotNull);
      expect(t!.label, 'Their beat');
      expect(t.isDevice, isTrue);
      // the placeholder id of a song that is not uploaded is never remembered
      rememberMusic(kDeviceLocalId, 'x', '');
      expect(musicById(kDeviceLocalId), isNull);
    });

    test('musicDocFields keeps the title of a song from the phone', () {
      final t = MusicTrack.uploaded(key: 'video/u/k.mp4', title: 'Beat');
      expect(musicDocFields(t), {
        'musicId': 'my:video/u/k.mp4',
        'musicTitle': 'Beat',
      });
    });

    test('old built-in tracks still resolve (old posts keep playing)', () {
      expect(musicById(kMusicLibrary.first.id), isNotNull);
      expect(kMusicLibrary.first.remote, isFalse);
    });

    test('titles come from the file name', () {
      expect(
        DeviceAudio.titleOf('/a/b/my_song-01.final.MP3'),
        'my song 01.final',
      );
      expect(DeviceAudio.titleOf('C:\\x\\Raat Ki Rani.m4a'), 'Raat Ki Rani');
      expect(DeviceAudio.titleOf('/a/.mp3'), '.mp3');
      expect(DeviceAudio.titleOf('/a/___.wav'), 'My sound');
    });
  });

  group('importing', () {
    test('a picked file is turned into a local track', () async {
      final src = File('${tmp.path}/Sunny_Day.mp3')
        ..writeAsBytesSync([1, 2, 3]);
      DeviceAudio.pickBackend = () async => src;
      String? asked;
      double? cap;
      AudioMerger.convertBackend = (input, output, max) async {
        asked = input;
        cap = max;
        File(output).writeAsBytesSync([9]);
        return 41.6;
      };
      final t = await DeviceAudio.pick();
      expect(asked, src.path);
      expect(cap, 60); // at most the length of the longest video
      expect(t, isNotNull);
      expect(t!.isLocal, isTrue);
      expect(t.title, 'Sunny Day');
      expect(t.seconds, 42);
      expect(File(t.localPath).existsSync(), isTrue);
      expect(t.localPath.endsWith('.mp4'), isTrue); // the storage accepts .mp4
    });

    test('closing the picker gives nothing', () async {
      DeviceAudio.pickBackend = () async => null;
      expect(await DeviceAudio.pick(), isNull);
    });

    test('a file that cannot be converted says so', () async {
      final src = File('${tmp.path}/bad.xyz')..writeAsBytesSync([1]);
      DeviceAudio.pickBackend = () async => src;
      AudioMerger.convertBackend = (a, b, c) async =>
          throw const MediaException('This file has no sound.');
      await expectLater(DeviceAudio.pick(), throwsA(isA<MediaException>()));
    });

    test('a missing file is reported', () async {
      DeviceAudio.pickBackend = () async => File('${tmp.path}/gone.mp3');
      await expectLater(DeviceAudio.pick(), throwsA(isA<MediaException>()));
    });
  });

  group('uploading', () {
    test('a local song becomes my:<key> after the upload', () async {
      final f = File('${tmp.path}/s.mp4')..writeAsBytesSync([1]);
      File? sent;
      DeviceAudio.uploadBackend = (file) async {
        sent = file;
        return 'm:video/u1/0123.mp4';
      };
      final up = await DeviceAudio.upload(
        MusicTrack.device(path: f.path, title: 'Beat'),
      );
      expect(sent?.path, f.path);
      expect(up.id, 'my:video/u1/0123.mp4');
      expect(up.title, 'Beat');
      expect(up.isLocal, isFalse);
    });

    test('other tracks are not uploaded', () async {
      var calls = 0;
      DeviceAudio.uploadBackend = (file) async {
        calls++;
        return 'm:x';
      };
      final apple = MusicTrack.apple(trackId: '1', title: 'A');
      expect(await DeviceAudio.upload(apple), same(apple));
      expect(calls, 0);
    });

    test('a strange answer is an error', () async {
      DeviceAudio.uploadBackend = (file) async => 'http://elsewhere';
      await expectLater(
        DeviceAudio.upload(MusicTrack.device(path: '/x', title: 't')),
        throwsA(isA<MediaException>()),
      );
    });
  });

  group('converter channel', () {
    test('toAac asks the phone for an mp4 next to the temp folder', () async {
      final src = File('${tmp.path}/in.wav')..writeAsBytesSync([1]);
      String? out;
      AudioMerger.convertBackend = (i, o, m) async {
        out = o;
        return 12;
      };
      final r = await AudioMerger.toAac(input: src);
      expect(r.seconds, 12);
      expect(r.file.path, out);
      expect(out, endsWith('.mp4'));
    });
  });

  group('the audio sheet', () {
    testWidgets('first tab is My phone, with no built-in songs', (
      tester,
    ) async {
      await _open(tester);
      expect(find.text('My phone'), findsOneWidget);
      expect(find.text('InstantGram'), findsNothing);
      expect(find.text('Volt Rush'), findsNothing);
      expect(find.byKey(const ValueKey('phoneNote')), findsOneWidget);
      expect(find.byKey(const ValueKey('pickDeviceAudio')), findsOneWidget);
      expect(find.text('Choose audio'), findsOneWidget);
    });

    testWidgets('choosing a file shows it, ready to use', (tester) async {
      final src = File('${tmp.path}/Night_Drive.mp3')..writeAsBytesSync([1]);
      DeviceAudio.pickBackend = () async => src;
      AudioMerger.convertBackend = (i, o, m) async {
        File(o).writeAsBytesSync([1]);
        return 75.4.clamp(0, 60).toDouble();
      };
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('pickDeviceAudio')));
      // real file access needs real time, then a pump to run what follows
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Night Drive'), findsOneWidget);
      expect(find.textContaining('From your phone'), findsOneWidget);
      expect(find.text('Choose another'), findsOneWidget);
      expect(find.byKey(const ValueKey('use_$kDeviceLocalId')), findsOneWidget);
    });

    testWidgets('a file that cannot be used shows a message', (tester) async {
      DeviceAudio.pickBackend = () async =>
          File('${tmp.path}/x.mp3')..writeAsBytesSync([1]);
      AudioMerger.convertBackend = (i, o, m) async =>
          throw const MediaException('This file has no sound.');
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('pickDeviceAudio')));
      // real file access needs real time, then a pump to run what follows
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('This file has no sound.'), findsOneWidget);
      expect(find.text('Choose audio'), findsOneWidget);
    });

    testWidgets('a song picked before is shown again', (tester) async {
      final cur = MusicTrack.device(
        path: '/x/y.mp4',
        title: 'Again',
        seconds: 20,
      );
      await _open(tester, current: cur);
      expect(find.text('Again'), findsOneWidget);
      expect(find.text('Selected'), findsOneWidget);
    });
  });
}
