import 'package:flutter_test/flutter_test.dart';

import 'package:instantgram/services/itunes_service.dart';
import 'package:instantgram/widgets/music_widgets.dart';

void main() {
  group('the InstantGram audio tab', () {
    test('there are at least 20 more songs than the 40 it started with', () {
      expect(kInstantStations.length * kStationSize, greaterThanOrEqualTo(60));
      expect(kInstantStations.length, greaterThanOrEqualTo(13));
    });

    test('every row is different and has something to ask Apple', () {
      final names = kInstantStations.map((s) => s.name).toSet();
      final terms = kInstantStations.map((s) => s.term).toSet();
      expect(names.length, kInstantStations.length);
      expect(terms.length, kInstantStations.length);
      for (final s in kInstantStations) {
        expect(s.name.trim(), isNotEmpty);
        expect(s.term.trim(), isNotEmpty);
        expect(s.term, isNot(contains('  ')));
      }
    });

    test('the newer moods are in the list', () {
      final names = kInstantStations.map((s) => s.name).toList();
      for (final want in [
        'Sad & soulful',
        'Bhakti',
        'Sufi & qawwali',
        '90s & 2000s',
        'Wedding',
        'EDM & drop',
      ]) {
        expect(names, contains(want));
      }
    });
  });

  group('the words in the audio sheet', () {
    test('it says you can bring your own audio', () {
      expect(kPhoneNote, contains('mp3'));
      expect(kPhoneNote.toLowerCase(), contains('phone'));
      expect(kInstantNote, contains('My phone'));
      expect(kAppleNote, contains('My phone'));
    });

    test('the old music brand is not named anywhere', () {
      for (final note in [kPhoneNote, kInstantNote, kAppleNote]) {
        expect(note.toLowerCase(), isNot(contains('epidemic')));
      }
    });

    test('the Apple previews are described as what they are', () {
      expect(kAppleNote, contains('30 second previews'));
      expect(kInstantNote, contains('Apple'));
    });
  });
}
