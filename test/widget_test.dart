import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/media_url.dart';
import 'package:instantgram/models/post.dart';
import 'package:instantgram/services/auth_service.dart';

void main() {
  test('username regex accepts valid and rejects invalid names', () {
    expect(AuthService.usernameRegex.hasMatch('aryan.shah_1'), isTrue);
    expect(AuthService.usernameRegex.hasMatch('ab'), isFalse);
    expect(AuthService.usernameRegex.hasMatch('Has Space'), isFalse);
  });

  group('media references', () {
    test('tg: and tgt: are turned into media-server addresses', () {
      expect(
        resolveMediaUrl('tg:123-abcdefghijklmnop'),
        endsWith('/m/123-abcdefghijklmnop'),
      );
      expect(
        resolveMediaUrl('tgt:123-abcdefghijklmnop'),
        endsWith('/t/123-abcdefghijklmnop'),
      );
      expect(
        resolveMediaUrl('https://example.com/a.jpg'),
        'https://example.com/a.jpg',
      );
      expect(resolveMediaUrl(''), '');
      expect(isMediaRef('tg:1-x'), isTrue);
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
      thumbRef: 'tgt:1-aaaaaaaaaaaaaaaa',
      videoWidth: 720,
      videoHeight: 1280,
    );

    test('uploaded clips are playable, old link posts are hidden', () {
      expect(post('video', 'tg:1-aaaaaaaaaaaaaaaa').isLegacyLink, isFalse);
      expect(
        post('video', 'https://youtube.com/shorts/x').isLegacyLink,
        isTrue,
      );
      expect(post('image', '').isLegacyLink, isFalse);
    });

    test('urls and aspect are derived from the stored references', () {
      final p = post('video', 'tg:1-aaaaaaaaaaaaaaaa');
      expect(p.videoUrl, endsWith('/m/1-aaaaaaaaaaaaaaaa'));
      expect(p.thumbnailUrl, endsWith('/t/1-aaaaaaaaaaaaaaaa'));
      expect(p.videoAspect, closeTo(0.5625, 0.001));
    });
  });
}
