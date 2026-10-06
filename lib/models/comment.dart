import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/media_url.dart';

/// How many comments the owner of a post can pin.
const int kMaxPinnedComments = 3;

class Comment {
  const Comment({
    required this.id,
    required this.authorId,
    required this.authorUsername,
    required this.authorPhotoUrl,
    required this.text,
    required this.createdAt,
    this.parentId = '',
    this.replyToUsername = '',
    this.gifUrl = '',
    this.gifAspect = 1,
    this.imageRef = '',
    this.clipId = '',
    this.clipThumbRef = '',
    this.likeCount = 0,
    this.edited = false,
    this.pinned = false,
  });

  final String id;
  final String authorId;
  final String authorUsername;
  final String authorPhotoUrl;
  final String text;
  final DateTime createdAt;

  /// The top-level comment this one answers ('' for a top-level comment).
  final String parentId;

  /// Who is being answered (shown as "@name" in front of a reply).
  final String replyToUsername;

  /// A Giphy link (only the link is stored).
  final String gifUrl;
  final double gifAspect;

  /// `m:<key>` of an uploaded photo.
  final String imageRef;

  /// A clip of the author's own, sent as an answer.
  final String clipId;
  final String clipThumbRef;
  final int likeCount;
  final bool edited;

  /// Pinned by the owner of the post: shown first (at most [kMaxPinnedComments] per post).
  final bool pinned;

  bool get isReply => parentId.isNotEmpty;
  bool get hasGif => gifUrl.isNotEmpty;
  bool get hasImage => imageRef.isNotEmpty;
  bool get hasClip => clipId.isNotEmpty;
  String get imageUrl => resolveMediaUrl(imageRef);
  String get clipThumbUrl => resolveMediaUrl(clipThumbRef);

  /// A short line for lists and share text.
  String get summary {
    if (text.trim().isNotEmpty) return text.trim();
    if (hasGif) return 'GIF';
    if (hasImage) return 'Photo';
    if (hasClip) return 'Clip';
    return '';
  }

  Comment copyWith({
    int? likeCount,
    String? text,
    bool? edited,
    bool? pinned,
  }) => Comment(
    id: id,
    authorId: authorId,
    authorUsername: authorUsername,
    authorPhotoUrl: authorPhotoUrl,
    text: text ?? this.text,
    createdAt: createdAt,
    parentId: parentId,
    replyToUsername: replyToUsername,
    gifUrl: gifUrl,
    gifAspect: gifAspect,
    imageRef: imageRef,
    clipId: clipId,
    clipThumbRef: clipThumbRef,
    likeCount: likeCount ?? this.likeCount,
    edited: edited ?? this.edited,
    pinned: pinned ?? this.pinned,
  );

  factory Comment.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const <String, dynamic>{};
    String s(Object? v) => v is String ? v : '';
    final ts = m['createdAt'];
    final a = m['gifAspect'];
    final n = m['likeCount'];
    return Comment(
      id: d.id,
      authorId: s(m['authorId']),
      authorUsername: s(m['authorUsername']),
      authorPhotoUrl: s(m['authorPhotoUrl']),
      text: s(m['text']),
      createdAt: ts is Timestamp ? ts.toDate() : DateTime.now(),
      parentId: s(m['parentId']),
      replyToUsername: s(m['replyToUsername']),
      gifUrl: s(m['gifUrl']),
      gifAspect: a is num && a > 0 ? a.toDouble() : 1,
      imageRef: s(m['imageUrl']),
      clipId: s(m['clipId']),
      clipThumbRef: s(m['clipThumb']),
      likeCount: n is num ? n.toInt().clamp(0, 1 << 30) : 0,
      edited: m['edited'] == true,
      pinned: m['pinned'] == true,
    );
  }
}

/// Puts replies under their comment: newest top-level comments first, replies oldest first.
/// A reply whose comment was deleted is shown as a top-level comment.
class CommentThread {
  const CommentThread(this.root, this.replies);
  final Comment root;
  final List<Comment> replies;
}

List<CommentThread> buildThreads(List<Comment> all) {
  final ids = {for (final c in all) c.id};
  final roots = <Comment>[];
  final byParent = <String, List<Comment>>{};
  for (final c in all) {
    if (c.parentId.isEmpty || !ids.contains(c.parentId)) {
      roots.add(c);
    } else {
      (byParent[c.parentId] ??= []).add(c);
    }
  }
  roots.sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    return b.createdAt.compareTo(a.createdAt);
  });
  return [
    for (final r in roots)
      CommentThread(
        r,
        [...?byParent[r.id]]
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
      ),
  ];
}
