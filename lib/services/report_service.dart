import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/post.dart';

/// Tests replace the Firestore write with this.
Future<void> Function(Map<String, Object?> data)? debugReportSink;

/// What a report saves in `reports/` (the admin panel's Reports tab reads it).
Map<String, Object?> reportData(
  Post post, {
  required String by,
  required String reason,
  required String text,
  String commentId = '',
  String comment = '',
  String commentAuthorId = '',
  String commentAuthorUsername = '',
}) {
  final onComment = commentId.isNotEmpty;
  return {
    'kind': onComment ? 'comment' : (post.isClip ? 'clip' : 'post'),
    'postId': post.id,
    if (onComment) 'commentId': commentId,
    if (onComment && comment.isNotEmpty)
      'comment': comment.length > 300 ? comment.substring(0, 300) : comment,
    'ownerId': onComment && commentAuthorId.isNotEmpty
        ? commentAuthorId
        : post.authorId,
    'ownerUsername': onComment && commentAuthorUsername.isNotEmpty
        ? commentAuthorUsername
        : post.authorUsername,
    'by': by,
    'reason': reason,
    'text': text.length > 2000 ? text.substring(0, 2000) : text,
    'status': 'open',
  };
}

/// Saves a report for the admin panel. False when it could not be saved (no internet...).
Future<bool> sendReport(
  Post post, {
  required String reason,
  required String text,
  String commentId = '',
  String comment = '',
  String commentAuthorId = '',
  String commentAuthorUsername = '',
}) async {
  try {
    final sink = debugReportSink;
    final by = sink != null
        ? 'tester'
        : (FirebaseAuth.instance.currentUser?.uid ?? '');
    if (by.isEmpty) return false;
    final data = reportData(
      post,
      by: by,
      reason: reason,
      text: text,
      commentId: commentId,
      comment: comment,
      commentAuthorId: commentAuthorId,
      commentAuthorUsername: commentAuthorUsername,
    );
    if (sink != null) {
      await sink(data);
      return true;
    }
    final db = FirebaseFirestore.instance;
    await db.collection('reports').add({
      ...data,
      'createdAt': FieldValue.serverTimestamp(),
    });
    if (commentId.isEmpty && post.authorId != by) {
      // counts once per person: enough reports hide the post (admin panel setting)
      try {
        final ref = db.collection('posts').doc(post.id);
        final batch = db.batch()
          ..set(ref.collection('reporters').doc(by), {
            'at': FieldValue.serverTimestamp(),
          })
          ..update(ref, {'reportCount': FieldValue.increment(1)});
        await batch.commit();
      } catch (_) {
        // reported before: the count stays
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// Saves a report about a chat (the admin panel may then read that chat). False on failure.
Future<bool> sendChatReport({
  required String chatId,
  required String otherUid,
  required String otherUsername,
  required String text,
}) async {
  try {
    final sink = debugReportSink;
    final by = sink != null
        ? 'tester'
        : (FirebaseAuth.instance.currentUser?.uid ?? '');
    if (by.isEmpty) return false;
    final data = <String, Object?>{
      'kind': 'chat',
      'chatId': chatId,
      'ownerId': otherUid,
      'ownerUsername': otherUsername,
      'by': by,
      'reason': 'chat',
      'text': text.length > 2000 ? text.substring(0, 2000) : text,
      'status': 'open',
    };
    if (sink != null) {
      await sink(data);
      return true;
    }
    await FirebaseFirestore.instance.collection('reports').add({
      ...data,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return true;
  } catch (_) {
    return false;
  }
}
