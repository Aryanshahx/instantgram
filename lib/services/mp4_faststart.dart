import 'dart:io';
import 'dart:typed_data';

/// "Fast start" for MP4 files, without re-encoding anything.
///
/// Phones write the index of an MP4 (the `moov` box) at the END of the file. A player that
/// streams the file over the internet then has to jump to the end first, read the index and
/// jump back before the first frame can be shown. That is the main reason a clip takes long to
/// start. This moves the index to the front and fixes the offsets inside it. The video and audio
/// bytes are copied exactly as they are (same quality, same size).
///
/// Anything unexpected (fragmented files, odd layouts, no space left, ...) simply returns the
/// original file, so a publish never fails because of this step.
class Mp4FastStart {
  /// Returns a new temporary file with the index at the front, or [input] itself when no change
  /// was needed or possible. The caller deletes the returned file when it is not [input].
  static Future<File> run(File input) async {
    try {
      return await _run(input) ?? input;
    } catch (_) {
      return input;
    }
  }

  static const _maxMoov = 64 * 1024 * 1024;
  static const _containers = {'moov', 'trak', 'mdia', 'minf', 'stbl'};

  static Future<File?> _run(File input) async {
    final total = await input.length();
    final raf = await input.open();
    try {
      final boxes = <_Box>[];
      var pos = 0;
      while (pos + 8 <= total) {
        await raf.setPosition(pos);
        final head = await raf.read(16);
        if (head.length < 8) break;
        final bd = ByteData.sublistView(head);
        var size = bd.getUint32(0);
        final type = String.fromCharCodes(head.sublist(4, 8));
        if (size == 1) {
          if (head.length < 16) return null;
          size = bd.getUint64(8);
        } else if (size == 0) {
          size = total - pos;
        }
        if (size < 8 || pos + size > total) return null;
        boxes.add(_Box(type, pos, size));
        pos += size;
      }
      if (pos != total) return null;

      final ftyp = boxes.indexWhere((b) => b.type == 'ftyp');
      final moov = boxes.indexWhere((b) => b.type == 'moov');
      final mdat = boxes.indexWhere((b) => b.type == 'mdat');
      if (ftyp != 0 || moov < 0 || mdat < 0) return null;
      if (boxes.any((b) => b.type == 'moof')) {
        return null; // fragmented: leave alone
      }
      if (moov < mdat) return null; // already starts fast
      final m = boxes[moov];
      if (m.size > _maxMoov) return null;

      await raf.setPosition(m.start);
      final moovBytes = Uint8List.fromList(await raf.read(m.size));
      if (moovBytes.length != m.size) return null;
      final headerLen = ByteData.sublistView(moovBytes).getUint32(0) == 1
          ? 16
          : 8;
      // everything after the first box moves back by the size of the index
      _patchOffsets(moovBytes, headerLen, moovBytes.length, m.size);

      final out = File(
        '${Directory.systemTemp.path}/instantgram_fast_${DateTime.now().microsecondsSinceEpoch}.mp4',
      );
      final sink = out.openWrite();
      try {
        Future<void> copy(_Box b) async {
          var p = b.start;
          final end = b.start + b.size;
          while (p < end) {
            final n = (end - p) > 1024 * 1024 ? 1024 * 1024 : (end - p);
            await raf.setPosition(p);
            sink.add(await raf.read(n));
            p += n;
          }
        }

        await copy(boxes[ftyp]);
        sink.add(moovBytes);
        for (var i = 0; i < boxes.length; i++) {
          if (i == ftyp || i == moov) continue;
          await copy(boxes[i]);
        }
        await sink.flush();
        await sink.close();
      } catch (e) {
        try {
          await sink.close();
        } catch (_) {}
        if (await out.exists()) await out.delete();
        rethrow;
      }
      if (await out.length() != total) {
        await out.delete();
        return null;
      }
      return out;
    } finally {
      await raf.close();
    }
  }

  /// Adds [delta] to every chunk offset (`stco` / `co64`) found inside [b] between [start]
  /// and [end]. Throws on anything malformed.
  static void _patchOffsets(Uint8List b, int start, int end, int delta) {
    final bd = ByteData.sublistView(b);
    var p = start;
    while (p + 8 <= end) {
      var size = bd.getUint32(p);
      final type = String.fromCharCodes(b.sublist(p + 4, p + 8));
      var header = 8;
      if (size == 1) {
        size = bd.getUint64(p + 8);
        header = 16;
      } else if (size == 0) {
        size = end - p;
      }
      if (size < header || p + size > end) {
        throw const FormatException('bad box');
      }
      if (_containers.contains(type)) {
        _patchOffsets(b, p + header, p + size, delta);
      } else if (type == 'stco') {
        final count = bd.getUint32(p + header + 4);
        final first = p + header + 8;
        if (first + count * 4 > p + size) throw const FormatException('stco');
        for (var i = 0; i < count; i++) {
          final v = bd.getUint32(first + i * 4) + delta;
          if (v > 0xFFFFFFFF) throw const FormatException('offset overflow');
          bd.setUint32(first + i * 4, v);
        }
      } else if (type == 'co64') {
        final count = bd.getUint32(p + header + 4);
        final first = p + header + 8;
        if (first + count * 8 > p + size) throw const FormatException('co64');
        for (var i = 0; i < count; i++) {
          bd.setUint64(first + i * 8, bd.getUint64(first + i * 8) + delta);
        }
      }
      p += size;
    }
  }
}

class _Box {
  _Box(this.type, this.start, this.size);
  final String type;
  final int start;
  final int size;
}
