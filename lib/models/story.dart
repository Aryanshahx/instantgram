import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/media_url.dart';

class Story {
  const Story({
    required this.id,
    required this.authorId,
    required this.username,
    required this.photoUrl,
    required this.imageRef,
    required this.createdAt,
  });

  final String id;
  final String authorId;
  final String username;
  final String photoUrl;
  final String imageRef;
  final DateTime createdAt;

  String get imageUrl => resolveMediaUrl(imageRef);

  factory Story.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const <String, dynamic>{};
    String s(Object? v) => v is String ? v : '';
    final ts = m['createdAt'];
    return Story(
      id: d.id,
      authorId: s(m['authorId']),
      username: s(m['authorUsername']),
      photoUrl: s(m['authorPhotoUrl']),
      imageRef: s(m['imageUrl']),
      createdAt: ts is Timestamp ? ts.toDate() : DateTime.now(),
    );
  }
}

class StoryGroup {
  StoryGroup({
    required this.authorId,
    required this.username,
    required this.photoUrl,
    required this.stories,
  });

  final String authorId;
  final String username;
  final String photoUrl;
  final List<Story> stories;
}
