import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/music.dart';
import 'package:instantgram/services/online_music_service.dart';
import 'package:instantgram/widgets/music_widgets.dart';

void main() {
  tearDown(() => OnlineMusicService.instance.backend = null);

  group('online music', () {
    test('a search sends the typed word and reads the tracks', () async {
      final sent = <Map<String, dynamic>>[];
      OnlineMusicService.instance.backend = (req) async {
        sent.add(req);
        return {
          'tracks': [
            {
              'id': '111',
              'title': 'Sunrise',
              'artist': 'Ann',
              'seconds': 143,
              'cover': 'https://c/x.jpg',
            },
            {'id': '', 'title': 'broken'},
            {'title': 'no id'},
          ],
          'hasMore': true,
          'nextOffset': 37,
        };
      };
      final page = await OnlineMusicService.instance.search(
        '  calm ',
        offset: 30,
      );
      expect(sent.single['op'], 'search');
      expect(sent.single['term'], 'calm');
      expect(sent.single['offset'], 30);
      expect(page.tracks.length, 1);
      expect(page.tracks.first.id, 'ov:111');
      expect(page.tracks.first.label, 'Sunrise \u00b7 Ann');
      expect(page.tracks.first.remote, isTrue);
      expect(page.tracks.first.remoteId, '111');
      expect(page.hasMore, isTrue);
      expect(page.next, 37);
    });

    test(
      'nothing typed sends an empty word (the server picks a default word)',
      () async {
        Map<String, dynamic>? sent;
        OnlineMusicService.instance.backend = (req) async {
          sent = req;
          return {'tracks': [], 'hasMore': false};
        };
        final page = await OnlineMusicService.instance.search('');
        expect(sent!['term'], '');
        expect(page.tracks, isEmpty);
        expect(page.hasMore, isFalse);
        expect(page.next, 0);
      },
    );

    test('the stream address is asked once and then kept', () async {
      var calls = 0;
      OnlineMusicService.instance.backend = (req) async {
        calls++;
        expect(req['op'], 'url');
        expect(req['id'], '222');
        return {'url': 'https://stream/222.mp3'};
      };
      final t = MusicTrack.online(uuid: '222', title: 'Two');
      expect(
        await OnlineMusicService.instance.audioUrl(t),
        'https://stream/222.mp3',
      );
      expect(
        await OnlineMusicService.instance.audioUrl(t),
        'https://stream/222.mp3',
      );
      expect(calls, 1);
    });

    test('a post stores only the id, title and artist', () {
      final t = MusicTrack.online(uuid: '333', title: 'Three', artist: 'Zed');
      final f = musicDocFields(t);
      expect(f['musicId'], 'ov:333');
      expect(f['musicTitle'], 'Three');
      expect(f['musicArtist'], 'Zed');
      expect(kOnlinePrefix, 'ov:');
    });
  });

  group('free music tab', () {
    testWidgets('quick genres search for their word', (tester) async {
      final terms = <String>[];
      OnlineMusicService.instance.backend = (req) async {
        terms.add(req['term'] as String);
        return {
          'tracks': [
            {
              'id': 'abc-1',
              'title': 'Song for ${req['term']}',
              'artist': 'Ann',
              'seconds': 100,
            },
          ],
          'hasMore': false,
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
      // the tab is gone: free music was not working, and it is not offered any more
      expect(find.text('Free music'), findsNothing);
      expect(find.byKey(const ValueKey('musicGenres')), findsNothing);
      expect(find.byKey(const ValueKey('musicSearch')), findsNothing);
      expect(find.byKey(const ValueKey('musicTab0')), findsOneWidget);
      expect(find.byKey(const ValueKey('musicTab1')), findsOneWidget);
    });
  });
}
