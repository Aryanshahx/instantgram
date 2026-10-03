import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:instantgram/services/mp4_faststart.dart';
import 'package:instantgram/services/photo_edit.dart';

Uint8List _box(String type, List<int> payload) {
  final out = BytesBuilder();
  final size = 8 + payload.length;
  out.add([size >> 24, (size >> 16) & 255, (size >> 8) & 255, size & 255]);
  out.add(type.codeUnits);
  out.add(payload);
  return out.toBytes();
}

Uint8List _u32(int v) =>
    Uint8List.fromList([v >> 24, (v >> 16) & 255, (v >> 8) & 255, v & 255]);

/// ftyp, free, mdat (with a recognisable payload), moov(trak(mdia(minf(stbl(stco)))))
/// Chunk offsets point at the payload inside mdat.
Uint8List _fakeMp4({required bool moovFirst}) {
  final ftyp = _box('ftyp', [...'isom'.codeUnits, 0, 0, 2, 0]);
  final free = _box('free', List.filled(12, 0));
  final payload = List<int>.generate(5000, (i) => (i * 7 + 3) & 255);

  Uint8List moovFor(int mdatStart) {
    final payloadStart = mdatStart + 8;
    final stco = _box('stco', [
      ..._u32(0), // version + flags
      ..._u32(2), // entries
      ..._u32(payloadStart),
      ..._u32(payloadStart + 1000),
    ]);
    final stbl = _box('stbl', stco);
    final minf = _box('minf', stbl);
    final mdia = _box('mdia', minf);
    final trak = _box('trak', mdia);
    return _box('moov', trak);
  }

  final mdat = _box('mdat', payload);
  final b = BytesBuilder()
    ..add(ftyp)
    ..add(free);
  if (moovFirst) {
    final moovLen = moovFor(0).length;
    final moov = moovFor(ftyp.length + free.length + moovLen);
    b
      ..add(moov)
      ..add(mdat);
  } else {
    final mdatStart = ftyp.length + free.length;
    b
      ..add(mdat)
      ..add(moovFor(mdatStart));
  }
  return b.toBytes();
}

List<String> _topLevel(Uint8List d) {
  final names = <String>[];
  var p = 0;
  while (p + 8 <= d.length) {
    final size = ByteData.sublistView(d).getUint32(p);
    names.add(String.fromCharCodes(d.sublist(p + 4, p + 8)));
    p += size;
  }
  return names;
}

int _stcoFirst(Uint8List d) {
  final i = _indexOf(d, 'stco'.codeUnits);
  return ByteData.sublistView(d).getUint32(i + 4 + 8);
}

int _indexOf(Uint8List d, List<int> needle) {
  for (var i = 0; i < d.length - needle.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (d[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

void main() {
  group('MP4 fast start', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('fs_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('moves the index to the front and fixes the offsets', () async {
      final src = File('${dir.path}/a.mp4')
        ..writeAsBytesSync(_fakeMp4(moovFirst: false));
      expect(_topLevel(src.readAsBytesSync()), [
        'ftyp',
        'free',
        'mdat',
        'moov',
      ]);

      final out = await Mp4FastStart.run(src);
      expect(out.path, isNot(src.path));
      final d = out.readAsBytesSync();
      expect(_topLevel(d), ['ftyp', 'moov', 'free', 'mdat']);
      expect(d.length, src.lengthSync());

      // the first chunk offset must point at the start of the (unchanged) payload
      final first = _stcoFirst(d);
      final expected = List<int>.generate(16, (i) => (i * 7 + 3) & 255);
      expect(d.sublist(first, first + 16), expected);
      out.deleteSync();
    });

    test('a file that already starts fast is left alone', () async {
      final src = File('${dir.path}/b.mp4')
        ..writeAsBytesSync(_fakeMp4(moovFirst: true));
      final out = await Mp4FastStart.run(src);
      expect(out.path, src.path);
    });

    test('garbage is returned untouched', () async {
      final src = File('${dir.path}/c.mp4')
        ..writeAsBytesSync(List.filled(100, 7));
      final out = await Mp4FastStart.run(src);
      expect(out.path, src.path);
    });

    test('a real phone-style file (set FASTSTART_SAMPLE)', () async {
      final sample = Platform.environment['FASTSTART_SAMPLE'];
      if (sample == null) return;
      final out = await Mp4FastStart.run(File(sample));
      expect(out.path, isNot(sample));
      File(
        '${Platform.environment['FASTSTART_OUT']}',
      ).writeAsBytesSync(out.readAsBytesSync());
    });
  });

  group('Photo editing', () {
    Uint8List sample() {
      // 40 x 20: left half red, right half blue
      final im = img.Image(width: 40, height: 20);
      for (final p in im) {
        p.r = p.x < 20 ? 255 : 0;
        p.g = 0;
        p.b = p.x < 20 ? 0 : 255;
      }
      return img.encodePng(im);
    }

    List<double> args(PhotoEdits e) => [
      e.turns.toDouble(),
      e.flip ? 1 : 0,
      e.crop.left,
      e.crop.top,
      e.crop.width,
      e.crop.height,
      ...e.colorMatrix,
    ];

    test('no edits keeps size and colours', () {
      final out = img.decodeJpg(
        PhotoEditor.renderBytes(sample(), args(PhotoEdits())),
      )!;
      expect((out.width, out.height), (40, 20));
      final px = out.getPixel(5, 5);
      expect(px.r, greaterThan(200));
      expect(px.b, lessThan(60));
    });

    test('rotate swaps the sides, flip mirrors, crop cuts', () {
      final rotated = img.decodeJpg(
        PhotoEditor.renderBytes(sample(), args(PhotoEdits(turns: 1))),
      )!;
      expect((rotated.width, rotated.height), (20, 40));
      // clockwise: the red (left) half ends up on top
      expect(rotated.getPixel(10, 5).r, greaterThan(200));
      expect(rotated.getPixel(10, 35).b, greaterThan(200));

      final flipped = img.decodeJpg(
        PhotoEditor.renderBytes(sample(), args(PhotoEdits(flip: true))),
      )!;
      expect(flipped.getPixel(5, 5).b, greaterThan(200));

      final cropped = img.decodeJpg(
        PhotoEditor.renderBytes(
          sample(),
          args(PhotoEdits(crop: const Rect.fromLTWH(0.5, 0, 0.5, 1))),
        ),
      )!;
      expect((cropped.width, cropped.height), (20, 20));
      expect(cropped.getPixel(5, 5).b, greaterThan(200));
    });

    test('Mono removes the colour', () {
      final mono = kPhotoFilters.indexWhere((f) => f.name == 'Mono');
      final out = img.decodeJpg(
        PhotoEditor.renderBytes(sample(), args(PhotoEdits(filter: mono))),
      )!;
      final px = out.getPixel(5, 5);
      expect((px.r - px.g).abs(), lessThan(12));
      expect((px.g - px.b).abs(), lessThan(12));
    });

    test('brightness makes it lighter', () {
      final out = img.decodeJpg(
        PhotoEditor.renderBytes(sample(), args(PhotoEdits(brightness: 0.8))),
      )!;
      expect(out.getPixel(5, 5).g, greaterThan(40));
    });

    test('isEmpty and crop helper', () {
      expect(PhotoEdits().isEmpty, isTrue);
      expect(PhotoEdits(flip: true).isEmpty, isFalse);
      final r = PhotoEditor.cropFor(4 / 3, 1);
      expect(r.width / r.height * (4 / 3), closeTo(1, 0.001));
      expect(r.center.dx, closeTo(0.5, 0.001));
    });
  });
}
