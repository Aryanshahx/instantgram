import 'dart:io';

import 'package:flutter/foundation.dart';

/// "Fast start" for MP4 videos (like qt-faststart / ffmpeg -movflags
/// +faststart). Phones write the index of the video (the "moov" box) at
/// the END of the file, so a player must download the end before it can
/// play. This moves the index to the front: playback starts after the
/// first few hundred KB.
class Mp4FastStart {
  Mp4FastStart._();

  static const _containers = {'moov', 'trak', 'mdia', 'minf', 'stbl', 'edts'};

  /// Top level boxes of [file]: (type, start, size).
  @visibleForTesting
  static Future<List<(String, int, int)>> boxes(File file) async {
    final raf = await file.open();
    try {
      final len = await raf.length();
      final out = <(String, int, int)>[];
      var pos = 0;
      while (pos + 8 <= len) {
        await raf.setPosition(pos);
        final h = await raf.read(16);
        if (h.length < 8) break;
        final bd = ByteData.sublistView(Uint8List.fromList(h));
        var size = bd.getUint32(0);
        final type = String.fromCharCodes(h.sublist(4, 8));
        if (size == 1) {
          if (h.length < 16) break;
          size = bd.getUint64(8);
        } else if (size == 0) {
          size = len - pos; // to the end of the file
        }
        if (size < 8 || pos + size > len) {
          // broken file: stop (and don't touch it)
          return const [];
        }
        out.add((type, pos, size));
        pos += size;
      }
      return out;
    } finally {
      await raf.close();
    }
  }

  /// True when the index is already in front of the video data.
  static Future<bool> isFastStart(File file) async {
    final b = await boxes(file);
    final moov = b.indexWhere((x) => x.$1 == 'moov');
    final mdat = b.indexWhere((x) => x.$1 == 'mdat');
    return moov >= 0 && (mdat < 0 || moov < mdat);
  }

  /// Writes a fast start copy of [input]. Returns the new file, or null
  /// when nothing had to be done (already fast, not an MP4, fragmented...).
  static Future<File?> process(File input, {File? output}) async {
    try {
      final b = await boxes(input);
      if (b.isEmpty || b.first.$1 != 'ftyp') return null;
      if (b.any((x) => x.$1 == 'moof')) return null; // fragmented: fine
      final moovI = b.indexWhere((x) => x.$1 == 'moov');
      final mdatI = b.indexWhere((x) => x.$1 == 'mdat');
      if (moovI < 0 || mdatI < 0 || moovI < mdatI) return null;
      final moov = b[moovI];
      final raf = await input.open();
      final Uint8List moovBytes;
      try {
        await raf.setPosition(moov.$2);
        moovBytes = Uint8List.fromList(await raf.read(moov.$3));
      } finally {
        await raf.close();
      }
      // the video data moves back by the size of the index
      if (!patchOffsets(moovBytes, moov.$3)) return null;
      final out =
          output ??
          File(
            '${input.parent.path}/fs_${DateTime.now().microsecondsSinceEpoch}.mp4',
          );
      final sink = out.openWrite();
      try {
        final src = await input.open();
        try {
          Future<void> copy(int start, int size) async {
            await src.setPosition(start);
            var left = size;
            while (left > 0) {
              final chunk = await src.read(left > 1 << 20 ? 1 << 20 : left);
              if (chunk.isEmpty) throw const FileSystemException('short read');
              sink.add(chunk);
              left -= chunk.length;
            }
          }

          // boxes before the video data (ftyp, free...), then the index,
          // then everything else
          for (var i = 0; i < mdatI; i++) {
            await copy(b[i].$2, b[i].$3);
          }
          sink.add(moovBytes);
          for (var i = mdatI; i < b.length; i++) {
            if (i == moovI) continue;
            await copy(b[i].$2, b[i].$3);
          }
        } finally {
          await src.close();
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (await out.length() != await input.length()) {
        await out.delete();
        return null;
      }
      return out;
    } catch (e) {
      debugPrint('faststart: $e');
      return null;
    }
  }

  /// Adds [delta] to every chunk offset (stco / co64) inside [moov].
  /// False when an offset would not fit (then the file is left alone).
  @visibleForTesting
  static bool patchOffsets(Uint8List moov, int delta) {
    final bd = ByteData.sublistView(moov);
    bool walk(int start, int end) {
      var pos = start;
      while (pos + 8 <= end) {
        var size = bd.getUint32(pos);
        final type = String.fromCharCodes(moov.sublist(pos + 4, pos + 8));
        var header = 8;
        if (size == 1) {
          if (pos + 16 > end) return false;
          size = bd.getUint64(pos + 8);
          header = 16;
        } else if (size == 0) {
          size = end - pos;
        }
        if (size < header || pos + size > end) return false;
        if (type == 'moov' && pos == 0) {
          if (!walk(pos + header, pos + size)) return false;
        } else if (_containers.contains(type)) {
          if (!walk(pos + header, pos + size)) return false;
        } else if (type == 'stco' || type == 'co64') {
          final body = pos + header;
          if (body + 8 > pos + size) return false;
          final count = bd.getUint32(body + 4);
          final wide = type == 'co64';
          final step = wide ? 8 : 4;
          if (body + 8 + count * step > pos + size) return false;
          for (var k = 0; k < count; k++) {
            final at = body + 8 + k * step;
            if (wide) {
              bd.setUint64(at, bd.getUint64(at) + delta);
            } else {
              final v = bd.getUint32(at) + delta;
              if (v > 0xffffffff) return false;
              bd.setUint32(at, v);
            }
          }
        }
        pos += size;
      }
      return true;
    }

    return walk(0, moov.length);
  }
}
