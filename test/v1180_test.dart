import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/errors.dart';
import 'package:instantgram/core/limits.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/music.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/services/audio_merger.dart';
import 'package:instantgram/services/itunes_service.dart';
import 'package:instantgram/widgets/music_widgets.dart';

Map<String, dynamic> _song(int id, {String? preview, String name = 'Song'}) => {
  'trackId': id,
  'trackName': '$name $id',
  'artistName': 'Artist $id',
  'artworkUrl100': 'https://is1.mzstatic.com/x/$id/100x100bb.jpg',
  if (preview != null) 'previewUrl': preview,
};

Post _post({bool baked = false}) => Post(
  id: 'p1',
  authorId: 'other',
  authorUsername: 'name',
  authorPhotoUrl: '',
  type: 'video',
  caption: 'hello',
  createdAt: DateTime(2026),
  videoRef: 'm:video/u/aaaaaaaaaaaaaaaa.mp4',
  musicId: 'it:77',
  musicBaked: baked,
);

void main() {
  late List<String> urls;
  setUp(() {
    urls = [];
    ItunesService.instance.backend = null;
    ItunesService.instance.clearCache();
  });
  tearDown(() {
    ItunesService.instance.backend = null;
    AudioMerger.backend = null;
  });

  group('Apple songs', () {
    test('a song knows it is from Apple', () {
      final t = MusicTrack.apple(
        trackId: '123',
        title: 'Calm Down',
        artist: 'Rema',
      );
      expect(t.id, 'it:123');
      expect(t.isApple, isTrue);
      expect(t.isOnline, isFalse);
      expect(t.remote, isTrue);
      expect(t.remoteId, '123');
      expect(t.label, 'Calm Down \u00b7 Rema');
      expect(musicDocFields(t)['musicTitle'], 'Calm Down');
      final o = MusicTrack.online(uuid: 'abc', title: 'X');
      expect(o.isApple, isFalse);
      expect(o.remoteId, 'abc');
      rememberMusic('it:555', 'Name', 'Band');
      expect(musicById('it:555')!.isApple, isTrue);
      expect(musicById('it:555')!.label, 'Name \u00b7 Band');
    });

    test('a search asks Apple and keeps only songs with a preview', () async {
      ItunesService.instance.backend = (url) async {
        urls.add(url);
        return {
          'results': [
            _song(1, preview: 'https://audio-ssl.itunes.apple.com/a1.m4a'),
            _song(2),
            _song(3, preview: 'http://insecure/a3.m4a'),
            _song(4, preview: 'https://audio-ssl.itunes.apple.com/a4.m4a'),
          ],
        };
      };
      final page = await ItunesService.instance.search(
        ' calm down ',
        offset: 30,
      );
      expect(urls.single, contains('https://itunes.apple.com/search?'));
      expect(urls.single, contains('term=calm+down'));
      expect(urls.single, contains('entity=song'));
      expect(urls.single, contains('offset=30'));
      expect(urls.single, contains('country=in'));
      expect(page.tracks.map((t) => t.id), ['it:1', 'it:4']);
      expect(page.tracks.first.previewUrl, endsWith('a1.m4a'));
      expect(page.tracks.first.cover, contains('200x200bb.jpg'));
      expect(page.hasMore, isFalse);
      expect(page.next, 34);
    });

    test('nothing typed shows the chart, in the chart order, once', () async {
      var calls = 0;
      ItunesService.instance.backend = (url) async {
        calls++;
        urls.add(url);
        if (url.contains('rss.applemarketingtools.com')) {
          return {
            'feed': {
              'results': [
                {'id': '30'},
                {'id': '10'},
                {'id': '20'},
              ],
            },
          };
        }
        return {
          'results': [
            _song(10, preview: 'https://p/10.m4a'),
            _song(30, preview: 'https://p/30.m4a'),
            _song(20),
          ],
        };
      };
      // a fresh instance of the cache: ask twice
      final a = await ItunesService.instance.search('');
      expect(a.tracks.map((t) => t.remoteId), ['30', '10']);
      expect(a.hasMore, isFalse);
      expect(urls.first, contains('/in/music/most-played/50/songs.json'));
      expect(urls.last, contains('lookup?id=30,10,20'));
      final before = calls;
      final b = await ItunesService.instance.search('  ');
      expect(b.tracks.length, 2);
      expect(calls, before, reason: 'the chart is kept for a while');
    });

    test('the preview address of an unknown song is looked up by id', () async {
      ItunesService.instance.backend = (url) async {
        urls.add(url);
        return {
          'results': [_song(9001, preview: 'https://p/9001.m4a')],
        };
      };
      final t = MusicTrack.apple(trackId: '9001', title: 'Late');
      expect(await ItunesService.instance.previewUrl(t), 'https://p/9001.m4a');
      expect(urls.single, contains('lookup?id=9001'));
      ItunesService.instance.backend = (url) async => {'results': []};
      final gone = MusicTrack.apple(trackId: '404', title: 'Gone');
      expect(
        () => ItunesService.instance.previewUrl(gone),
        throwsA(isA<MediaException>()),
      );
    });
  });

  group('song into video', () {
    test('the length is the shortest of video, song and 30 seconds', () {
      expect(mergedSeconds(video: 12, song: 30), 12);
      expect(mergedSeconds(video: 45, song: 30.02), 30);
      expect(mergedSeconds(video: 45, song: 29.6), 29.6);
      expect(mergedSeconds(video: 0, song: 30), 30);
      expect(mergedSeconds(video: 20, song: 0), 20);
      expect(kSongPreviewSeconds, 30);
    });

    test('the command mirrors what the phone does', () {
      expect(kFfmpegMergeCommand, contains('-map 0:v:0 -map 1:a:0'));
      expect(kFfmpegMergeCommand, contains('-c:v copy -c:a copy'));
      expect(kFfmpegMergeCommand, contains('-t 30 -shortest'));
      expect(kFfmpegMergeCommand, contains('+faststart'));
      final sh = File('tools/merge_audio.sh').readAsStringSync();
      expect(sh, contains('-map 0:v:0 -map 1:a:0'));
      expect(sh, contains('-t 30 -shortest'));
    });

    test('the merger sends the files and reports the length', () async {
      String? sentVideo;
      double? sentMax;
      AudioMerger.backend = (v, a, o, max) async {
        sentVideo = v;
        sentMax = max;
        expect(a, '/song.m4a');
        expect(o, endsWith('.mp4'));
        return 21.4;
      };
      final r = await AudioMerger.merge(
        video: File('/v.mp4'),
        audio: File('/song.m4a'),
      );
      expect(sentVideo, '/v.mp4');
      expect(sentMax, 30);
      expect(r.seconds, 21.4);
      expect(r.file.path, endsWith('.mp4'));
    });

    test('a failure of the phone becomes a readable message', () async {
      AudioMerger.backend = (v, a, o, max) async =>
          throw PlatformException(code: 'merge_failed', message: 'not AAC');
      expect(
        () => AudioMerger.merge(video: File('/v.mp4'), audio: File('/s.m4a')),
        throwsA(
          isA<MediaException>().having((e) => e.message, 'message', 'not AAC'),
        ),
      );
    });

    test('a post with the song inside plays nothing on top', () {
      rememberMusic('it:77', 'Hit', 'Band');
      expect(_post().playableMusic?.id, 'it:77');
      expect(_post(baked: true).playableMusic, isNull);
      expect(_post(baked: true).hasMusic, isTrue, reason: 'the name stays');
    });

    test('the android plugin and its channel are in the project', () {
      final java = File(
        'packages/audio_merge/android/src/main/java/com/hypertechlabs/audio_merge/AudioMerger.java',
      ).readAsStringSync();
      expect(java, contains('MediaMuxer'));
      expect(java, contains('audio/mp4a-latm'));
      final plugin = File(
        'packages/audio_merge/android/src/main/java/com/hypertechlabs/audio_merge/AudioMergePlugin.java',
      ).readAsStringSync();
      expect(plugin, contains('com.hypertechlabs.audio_merge'));
      expect(
        File('packages/audio_merge/pubspec.yaml').readAsStringSync(),
        contains('pluginClass: AudioMergePlugin'),
      );
    });
  });

  group('hit songs tab', () {
    testWidgets('shows the chart, the 30 second note and the genres', (
      tester,
    ) async {
      final asked = <String>[];
      ItunesService.instance.backend = (url) async {
        asked.add(url);
        if (url.contains('rss.applemarketingtools.com')) {
          return {
            'feed': {
              'results': [
                {'id': '1'},
              ],
            },
          };
        }
        if (url.contains('lookup')) {
          return {
            'results': [_song(1, preview: 'https://p/1.m4a', name: 'Hit')],
          };
        }
        return {
          'results': [_song(2, preview: 'https://p/2.m4a', name: 'Found')],
        };
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => pickMusic(c),
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
      await tester.tap(find.text('Hit songs'));
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const ValueKey('appleNote')), findsOneWidget);
      expect(find.text('Hit 1'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('genre_Bollywood')));
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(asked.last, contains('term=Bollywood'));
      expect(find.text('Found 2'), findsOneWidget);
    });
  });
}
