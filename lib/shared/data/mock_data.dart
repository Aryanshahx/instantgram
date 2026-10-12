import '../models/chat.dart';
import '../models/post.dart';

/// Temporary demo content. Will be replaced by real data from the
/// Vercel API + Tigris storage in the next steps.
class MockData {
  MockData._();

  static String _img(String seed, int w, int h) =>
      'https://picsum.photos/seed/$seed/$w/$h';

  static String avatar(String seed) => _img('ig-av-$seed', 200, 200);

  static final List<Story> stories = [
    Story(username: 'riya', avatarUrl: avatar('riya')),
    Story(username: 'kabir', avatarUrl: avatar('kabir')),
    Story(username: 'meera', avatarUrl: avatar('meera')),
    Story(username: 'dev.codes', avatarUrl: avatar('dev')),
    Story(username: 'travelwithsam', avatarUrl: avatar('sam')),
  ];

  static final List<Post> feed = [
    Post(
      id: 'p1',
      username: 'aryan',
      avatarUrl: avatar('aryan'),
      imageUrl: _img('ig-feed-1', 1080, 1350),
      caption: 'First post on InstantGram 🚀 #instantgram',
      likes: 24,
      comments: 3,
      createdAt: DateTime.now().subtract(const Duration(hours: 2)),
    ),
    Post(
      id: 'p2',
      username: 'riya',
      avatarUrl: avatar('riya'),
      imageUrl: _img('ig-feed-2', 1080, 1350),
      caption: 'Golden hour ✨',
      likes: 132,
      comments: 12,
      createdAt: DateTime.now().subtract(const Duration(hours: 9)),
    ),
    Post(
      id: 'p3',
      username: 'travelwithsam',
      avatarUrl: avatar('sam'),
      imageUrl: _img('ig-feed-3', 1080, 1080),
      caption: 'Mountains are calling 🏔️ #travel',
      likes: 891,
      comments: 40,
      aspectRatio: 1,
      createdAt: DateTime.now().subtract(const Duration(days: 1)),
    ),
  ];

  static final List<Post> explore = [
    Post(
      id: 'e1',
      username: 'aryan',
      avatarUrl: avatar('aryan'),
      imageUrl: _img('ig-ex-1', 540, 960),
      caption: 'street vibes',
      likes: 2,
      aspectRatio: 9 / 16,
      isVideo: true,
      pinned: true,
      tags: ['instantgram'],
    ),
    Post(
      id: 'e2',
      username: 'aryan',
      avatarUrl: avatar('aryan'),
      imageUrl: _img('ig-ex-2', 540, 960),
      caption: 'ringtone',
      aspectRatio: 9 / 16,
      isVideo: true,
      pinned: true,
      tags: ['max'],
    ),
    Post(
      id: 'e3',
      username: 'kabir',
      avatarUrl: avatar('kabir'),
      imageUrl: '',
      caption: 'processing clip',
      aspectRatio: 16 / 9,
      isVideo: true,
      pinned: true,
    ),
    Post(
      id: 'e4',
      username: 'aryan',
      avatarUrl: avatar('aryan'),
      imageUrl: _img('ig-ex-4', 600, 600),
      caption: 'new logo',
      likes: 1,
      aspectRatio: 1,
      pinned: true,
      tags: ['instantgram'],
    ),
    Post(
      id: 'e5',
      username: 'meera',
      avatarUrl: avatar('meera'),
      imageUrl: _img('ig-ex-5', 600, 750),
      caption: 'coffee first',
      likes: 18,
      tags: ['max'],
    ),
    Post(
      id: 'e6',
      username: 'dev.codes',
      avatarUrl: avatar('dev'),
      imageUrl: _img('ig-ex-6', 600, 900),
      caption: 'late night coding',
      likes: 57,
      aspectRatio: 2 / 3,
      tags: ['instantgram'],
    ),
    Post(
      id: 'e7',
      username: 'travelwithsam',
      avatarUrl: avatar('sam'),
      imageUrl: _img('ig-ex-7', 600, 600),
      caption: 'beach day',
      likes: 230,
      aspectRatio: 1,
    ),
    Post(
      id: 'e8',
      username: 'riya',
      avatarUrl: avatar('riya'),
      imageUrl: _img('ig-ex-8', 540, 960),
      caption: 'dance practice',
      likes: 77,
      aspectRatio: 9 / 16,
      isVideo: true,
    ),
  ];

  static const List<String> trendingTags = ['instantgram', 'max', 'travel'];

  static final List<ClipItem> clips = [
    ClipItem(
      id: 'c1',
      username: 'aryan',
      avatarUrl: avatar('aryan'),
      videoUrl: 'https://flutter.github.io/assets-for-api-docs/assets/videos/butterfly.mp4',
      coverUrl: _img('ig-clip-1', 540, 960),
      caption: 'Bbb',
      likes: 2,
      comments: 1,
      reposts: 1,
    ),
    ClipItem(
      id: 'c2',
      username: 'riya',
      avatarUrl: avatar('riya'),
      videoUrl:
          'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
      coverUrl: _img('ig-clip-2', 540, 960),
      caption: 'Busy bee 🐝',
      likes: 48,
      comments: 6,
      reposts: 2,
    ),
  ];

  static final List<ChatThread> chats = [
    ChatThread(
      id: 't1',
      name: 'riya',
      avatarUrl: avatar('riya'),
      messages: [
        ChatMessage(
          text: 'Hey! Saw your new post 🔥',
          fromMe: false,
          sentAt: DateTime.now().subtract(const Duration(days: 1, hours: 2)),
        ),
        ChatMessage(
          text: 'Chvk',
          fromMe: true,
          sentAt: DateTime.now().subtract(const Duration(days: 1)),
        ),
      ],
    ),
  ];
}
