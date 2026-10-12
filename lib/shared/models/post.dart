class Post {
  Post({
    required this.id,
    required this.username,
    required this.avatarUrl,
    required this.imageUrl,
    this.caption = '',
    this.likes = 0,
    this.comments = 0,
    this.reposts = 0,
    this.aspectRatio = 4 / 5,
    this.isVideo = false,
    this.pinned = false,
    this.tags = const [],
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String username;
  final String avatarUrl;
  final String imageUrl;
  final String caption;
  final int likes;
  final int comments;
  final int reposts;

  /// width / height of the media
  final double aspectRatio;
  final bool isVideo;
  final bool pinned;
  final List<String> tags;
  final DateTime createdAt;
}

class ClipItem {
  const ClipItem({
    required this.id,
    required this.username,
    required this.avatarUrl,
    required this.videoUrl,
    required this.coverUrl,
    this.caption = '',
    this.likes = 0,
    this.comments = 0,
    this.reposts = 0,
  });

  final String id;
  final String username;
  final String avatarUrl;
  final String videoUrl;
  final String coverUrl;
  final String caption;
  final int likes;
  final int comments;
  final int reposts;
}

class Story {
  const Story({required this.username, required this.avatarUrl});

  final String username;
  final String avatarUrl;
}
