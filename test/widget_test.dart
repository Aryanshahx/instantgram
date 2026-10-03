import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/media_url.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/services/auth_service.dart';
import 'package:instantgram/services/media_service.dart';

void main() {
  test('username regex accepts valid and rejects invalid names', () {
    expect(AuthService.usernameRegex.hasMatch('aryan.shah_1'), isTrue);
    expect(AuthService.usernameRegex.hasMatch('ab'), isFalse);
    expect(AuthService.usernameRegex.hasMatch('Has Space'), isFalse);
  });

  group('media references', () {
    test('m: references become public bucket addresses', () {
      expect(
        resolveMediaUrl('m:video/uid1/0123abcd.mp4'),
        endsWith('/video/uid1/0123abcd.mp4'),
      );
      expect(
        resolveMediaUrl('m:thumb/uid1/0123abcd.jpg'),
        startsWith(mediaPublicBase),
      );
      expect(resolveMediaUrl('tg:123-abcdefghijklmnop'), '');
      expect(resolveMediaUrl('tgt:123-abcdefghijklmnop'), '');
      expect(isRemovedStorageRef('tg:1-x'), isTrue);
      expect(isRemovedStorageRef('m:image/u/x.jpg'), isFalse);
      expect(
        resolveMediaUrl('https://example.com/a.jpg'),
        'https://example.com/a.jpg',
      );
      expect(resolveMediaUrl(''), '');
      expect(isMediaRef('m:image/u/x.jpg'), isTrue);
      expect(isMediaRef('tg:1-x'), isFalse);
      expect(isMediaRef('https://x'), isFalse);
    });

    test('durations are formatted as m:ss', () {
      expect(formatDuration(0), '0:00');
      expect(formatDuration(9), '0:09');
      expect(formatDuration(83), '1:23');
      expect(formatDuration(60), '1:00');
    });
  });

  group('Post', () {
    Post post(String type, String video) => Post(
      id: 'p',
      authorId: 'u',
      authorUsername: 'name',
      authorPhotoUrl: '',
      type: type,
      caption: '',
      createdAt: DateTime(2026),
      videoRef: video,
      thumbRef: 'm:thumb/u/aaaaaaaaaaaaaaaa.jpg',
      videoWidth: 720,
      videoHeight: 1280,
    );

    test('uploaded clips are playable, old link posts are hidden', () {
      expect(
        post('video', 'm:video/u/aaaaaaaaaaaaaaaa.mp4').isLegacyLink,
        isFalse,
      );
      expect(post('video', 'tg:1-aaaaaaaaaaaaaaaa').isLegacyLink, isTrue);
      expect(
        post('video', 'https://youtube.com/shorts/x').isLegacyLink,
        isTrue,
      );
      expect(post('image', '').isLegacyLink, isFalse);
    });

    test('urls and aspect are derived from the stored references', () {
      final p = post('video', 'm:video/u/aaaaaaaaaaaaaaaa.mp4');
      expect(p.videoUrl, endsWith('/video/u/aaaaaaaaaaaaaaaa.mp4'));
      expect(p.thumbnailUrl, endsWith('/thumb/u/aaaaaaaaaaaaaaaa.jpg'));
      expect(p.videoAspect, closeTo(0.5625, 0.001));
    });
  });

  group('photo formats', () {
    Future<bool> check(List<int> bytes) async {
      final dir = await Directory.systemTemp.createTemp('igtest');
      final f = File('${dir.path}/p.bin')..writeAsBytesSync(bytes);
      try {
        return await MediaService.isSupportedImage(f);
      } finally {
        await dir.delete(recursive: true);
      }
    }

    test('JPEG, PNG, GIF and WebP are accepted', () async {
      expect(
        await check([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0]),
        isTrue,
      );
      expect(
        await check([
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
          0,
          0,
          0,
          0,
        ]),
        isTrue,
      );
      expect(await check('GIF89a......'.codeUnits), isTrue);
      expect(await check('RIFF....WEBP'.codeUnits), isTrue);
    });

    test('HEIC and unknown files are rejected', () async {
      expect(
        await check([
          0,
          0,
          0,
          0x18,
          0x66,
          0x74,
          0x79,
          0x70,
          0x68,
          0x65,
          0x69,
          0x63,
        ]),
        isFalse,
      );
      expect(await check('hello'.codeUnits), isFalse);
      expect(await check(<int>[]), isFalse);
    });
  });
}
