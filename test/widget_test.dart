import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/models/video_link.dart';
import 'package:instantgram/services/auth_service.dart';

void main() {
  test('username regex accepts valid and rejects invalid names', () {
    expect(AuthService.usernameRegex.hasMatch('aryan.shah_1'), isTrue);
    expect(AuthService.usernameRegex.hasMatch('ab'), isFalse);
    expect(AuthService.usernameRegex.hasMatch('Has Space'), isFalse);
  });

  group('VideoLink.parse', () {
    test('YouTube Shorts / watch / youtu.be', () {
      final a = VideoLink.parse('https://www.youtube.com/shorts/dQw4w9WgXcQ');
      final b = VideoLink.parse('https://youtu.be/dQw4w9WgXcQ?si=abc');
      final c = VideoLink.parse('https://m.youtube.com/watch?v=dQw4w9WgXcQ');
      for (final l in [a, b, c]) {
        expect(l, isNotNull);
        expect(l!.platform, VideoPlatform.youtube);
        expect(l.id, 'dQw4w9WgXcQ');
      }
    });

    test('TikTok full and short links', () {
      final full =
          VideoLink.parse('https://www.tiktok.com/@user/video/7234567890123456789');
      expect(full!.platform, VideoPlatform.tiktok);
      expect(full.id, '7234567890123456789');
      expect(full.embedUrl, 'https://www.tiktok.com/embed/v2/7234567890123456789');

      final short = VideoLink.parse('https://vm.tiktok.com/ZMabc123/');
      expect(short!.platform, VideoPlatform.tiktok);
      expect(short.id, isNull);
    });

    test('Instagram reels and posts', () {
      final r = VideoLink.parse('https://www.instagram.com/reel/C1a2B3c4D5e/?igsh=xyz');
      expect(r!.platform, VideoPlatform.instagram);
      expect(r.id, 'reel/C1a2B3c4D5e');
      expect(r.embedUrl, 'https://www.instagram.com/reel/C1a2B3c4D5e/embed/');

      final u = VideoLink.parse('https://www.instagram.com/someone/reel/C1a2B3c4D5e/');
      expect(u!.id, 'reel/C1a2B3c4D5e');
    });

    test('rejects unsupported links', () {
      expect(VideoLink.parse(''), isNull);
      expect(VideoLink.parse('hello world'), isNull);
      expect(VideoLink.parse('https://example.com/video.mp4'), isNull);
      expect(VideoLink.parse('https://www.youtube.com/'), isNull);
    });
  });
}
