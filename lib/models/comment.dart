import 'package:cloud_firestore/cloud_firestore.dart';

class Comment {
  const Comment({
    required this.id,
    required this.authorId,
    required this.authorUsername,
    required this.authorPhotoUrl,
    required this.text,
    required this.createdAt,
  });

  final String id;
  final String authorId;
  final String authorUsername;
  final String authorPhotoUrl;
  final String text;
  final DateTime createdAt;

  factory Comment.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const <String, dynamic>{};
    String s(Object? v) => v is String ? v : '';
    final ts = m['createdAt'];
    return Comment(
      id: d.id,
      authorId: s(m['authorId']),
      authorUsername: s(m['authorUsername']),
      authorPhotoUrl: s(m['authorPhotoUrl']),
      text: s(m['text']),
      createdAt: ts is Timestamp ? ts.toDate() : DateTime.now(),
    );
  }
}
