import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/errors.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/music.dart';
import 'package:instantgram/services/itunes_service.dart';
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

/// Two songs for [term]; [ids] keeps them apart between stations.
Map<String, dynamic> _answer(String term, int base) => {
  'results': [
    {
      'trackId': base,
      'trackName': '$term one',
      'artistName': 'Singer $base',
      'artworkUrl100': 'https://cdn/100x100bb.jpg',
      'previewUrl': 'https://cdn/$base.m4a',
    },
    {
      'trackId': base + 1,
      'trackName': '$term two',
      'artistName': 'Singer ${base + 1}',
      'previewUrl': 'https://cdn/${base + 1}.m4a',
    },
  ],
};

void main() {
  setUp(() {
    ItunesService.instance.clearCache();
    ItunesService.instance.backend = null;
  });
  tearDown(() {
    ItunesService.instance.clearCache();
    ItunesService.instance.backend = null;
  });

  group('the InstantGram audio tab (service)', () {
    test('the rows are built from the picked searches', () async {
      final asked = <String>[];
      ItunesService.instance.backend = (url) async {
        asked.add(url);
        final m = RegExp(r'term=([^&]+)').firstMatch(url);
        final term = Uri.decodeQueryComponent(m!.group(1)!);
        return _answer(term, asked.length * 10);
      };
      final rows = await ItunesService.instance.curated();
      expect(asked.length, kInstantStations.length);
      expect(rows.length, kInstantStations.length);
      expect(rows.first.station.name, kInstantStations.first.name);
      expect(rows.first.tracks.length, 2);
      expect(rows.first.tracks.first.id, startsWith(kApplePrefix));
      expect(rows.first.tracks.first.seconds, 30);
      expect(rows.first.tracks.first.artist, isNotEmpty);
    });

    test('a second call within 30 minutes asks nothing again', () async {
      var calls = 0;
      ItunesService.instance.backend = (url) async {
        calls++;
        return _answer('x', calls * 100);
      };
      await ItunesService.instance.curated();
      expect(calls, kInstantStations.length);
      await ItunesService.instance.curated();
      expect(calls, kInstantStations.length); // still cached
      await ItunesService.instance.curated(force: true);
      expect(calls, kInstantStations.length * 2);
    });

    test('one station failing does not empty the tab', () async {
      var n = 0;
      ItunesService.instance.backend = (url) async {
        n++;
        if (n == 1) throw const MediaException('busy');
        return _answer('ok', n * 10);
      };
      final rows = await ItunesService.instance.curated();
      expect(rows.length, kInstantStations.length - 1);
      expect(rows.first.station.name, kInstantStations[1].name);
    });

    test('the same song is only listed once', () async {
      ItunesService.instance.backend = (url) async => {
        'results': [
          {
            'trackId': 777,
            'trackName': 'Same song',
            'artistName': 'A',
            'previewUrl': 'https://cdn/777.m4a',
          },
        ],
      };
      final rows = await ItunesService.instance.curated();
      final all = [for (final r in rows) ...r.tracks];
      expect(all.map((t) => t.id).toSet().length, 1);
      expect(all.length, 1);
    });

    test('songs without a preview are left out', () async {
      ItunesService.instance.backend = (url) async => {
        'results': [
          {'trackId': 1, 'trackName': 'No preview'},
          {
            'trackId': 2,
            'trackName': 'Has one',
            'previewUrl': 'https://cdn/2.m4a',
          },
        ],
      };
      final rows = await ItunesService.instance.curated();
      final all = [for (final r in rows) ...r.tracks];
      expect(all.length, 1);
      expect(all.first.title, 'Has one');
    });
  });

  group('the audio sheet', () {
    testWidgets('two tabs: my phone and InstantGram audio', (tester) async {
      await _open(tester);
      expect(find.byKey(const ValueKey('musicTab0')), findsOneWidget);
      expect(find.byKey(const ValueKey('musicTab1')), findsOneWidget);
      expect(find.text('My phone'), findsOneWidget);
      expect(find.text('InstantGram audio'), findsOneWidget);
      // the search tabs are gone: they were not working
      expect(find.byKey(const ValueKey('musicTab2')), findsNothing);
      expect(find.byKey(const ValueKey('musicTab3')), findsNothing);
      expect(find.text('Hit songs'), findsNothing);
      expect(find.text('Free music'), findsNothing);
    });

    testWidgets('the InstantGram tab shows the picked rows', (tester) async {
      var n = 0;
      ItunesService.instance.backend = (url) async {
        n++;
        final m = RegExp(r'term=([^&]+)').firstMatch(url);
        return _answer(Uri.decodeQueryComponent(m!.group(1)!), n * 10);
      };
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('musicTab1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('instantList')), findsOneWidget);
      expect(find.text(kInstantStations.first.name), findsOneWidget);
      expect(find.text('bollywood hits one'), findsOneWidget);
      expect(find.textContaining('Singer 10'), findsWidgets);
      // the list is lazy, so only the rows that fit are built
      expect(find.text('Use'), findsWidgets);
      expect(find.text(kInstantStations[1].name), findsOneWidget);
    });

    testWidgets('a song from a row can be picked', (tester) async {
      var n = 0;
      ItunesService.instance.backend = (url) async {
        n++;
        return _answer('pick me', n * 10);
      };
      MusicTrack? chosen;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async => chosen = await pickMusic(c),
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
      await tester.tap(find.byKey(const ValueKey('musicTab1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('use_it:10')));
      await tester.pumpAndSettle();
      expect(chosen, isNotNull);
      expect(chosen!.id, 'it:10');
      expect(chosen!.title, 'pick me one');
    });

    testWidgets('when every row fails there is a way to try again', (
      tester,
    ) async {
      var fail = true;
      ItunesService.instance.backend = (url) async {
        if (fail) {
          throw const MediaException('Could not reach the song service.');
        }
        return _answer('later', 5);
      };
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('musicTab1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('No songs right now'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('instantList')), findsOneWidget);
      expect(find.text('later one'), findsOneWidget);
    });

    testWidgets('an error from the service is shown with a retry', (
      tester,
    ) async {
      var fail = true;
      ItunesService.instance.backend = (url) async {
        if (fail) {
          throw StateError('boom');
        }
        return _answer('ok', 9);
      };
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('musicTab1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // a real crash of the service is shown, not swallowed
      expect(find.byKey(const ValueKey('instantList')), findsNothing);
      fail = false;
      await tester.tap(find.text('Try again').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('instantList')), findsOneWidget);
    });

    testWidgets('a song from a tab that is gone still opens the sheet', (
      tester,
    ) async {
      ItunesService.instance.backend = (url) async => _answer('back', 3);
      await _open(
        tester,
        current: MusicTrack.apple(trackId: '4242', title: 'Old'),
      );
      // the sheet opens on your own audio; the old song keeps playing in the post
      expect(find.byKey(const ValueKey('musicTab0')), findsOneWidget);
      expect(find.byKey(const ValueKey('instantList')), findsNothing);
      expect(find.byKey(const ValueKey('appleNote')), findsNothing);
    });
  });
}
