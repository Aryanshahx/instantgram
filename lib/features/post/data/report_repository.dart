import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/config/app_info.dart';
import '../../../core/services/api_client.dart';
import '../../../shared/models/post.dart';
import '../../../shared/models/user_profile.dart';

/// One report reason + a ready-made message the user can edit.
class ReportReason {
  const ReportReason(this.title, this.icon, this.template);
  final String title;
  final IconData icon;
  final String template;

  /// "{item}" becomes "clip" or "post".
  String message(String item) => template.replaceAll('{item}', item);
}

const List<ReportReason> kReportReasons = [
  ReportReason(
    'Spam',
    Icons.report_gmailerrorred,
    'This {item} is spam or misleading.',
  ),
  ReportReason(
    'Nudity or sexual content',
    Icons.no_adult_content,
    'This {item} shows nudity or sexual content.',
  ),
  ReportReason(
    'Hate speech',
    Icons.record_voice_over_outlined,
    'This {item} contains hate speech or hateful symbols.',
  ),
  ReportReason(
    'Violence or dangerous acts',
    Icons.dangerous_outlined,
    'This {item} shows violence or dangerous acts.',
  ),
  ReportReason(
    'Bullying or harassment',
    Icons.sentiment_very_dissatisfied_outlined,
    'This {item} is bullying or harassing someone.',
  ),
  ReportReason(
    'Scam or fraud',
    Icons.money_off,
    'This {item} looks like a scam or fraud.',
  ),
  ReportReason(
    'False information',
    Icons.fact_check_outlined,
    'This {item} spreads false information.',
  ),
  ReportReason(
    'Copyright',
    Icons.copyright,
    'This {item} uses my content without permission.',
  ),
  // v0.20: hidden at once (on 1 report) until the team checks it
  ReportReason(
    kChildSafetyReason,
    Icons.child_care,
    'This {item} may harm or show a child in an unsafe way.',
  ),
  ReportReason('Something else', Icons.more_horiz, ''),
];

/// v0.20: this reason hides the item at once.
const String kChildSafetyReason = 'Child safety';

class AlreadyReportedException implements Exception {
  const AlreadyReportedException();
}

/// A ready email (subject + body).
class ReportEmail {
  const ReportEmail(this.subject, this.body);
  final String subject;
  final String body;
}

/// Reports are sent by email to the InstantGram team.
class ReportRepository {
  ReportRepository._();
  static final ReportRepository instance = ReportRepository._();

  static const String to = AppInfo.supportEmail;

  static const List<String> kinds = ['post', 'clip', 'comment', 'user'];

  /// v0.13: the report as saved in `reports` (the admin website lists
  /// them). The email is still opened too.
  static Map<String, dynamic> reportData({
    required String kind,
    required String reporterUid,
    String reporterUsername = '',
    String targetId = '',
    String postId = '',
    String targetUid = '',
    String reason = '',
    String message = '',
  }) {
    String cut(String s, int n) => s.length > n ? s.substring(0, n) : s;
    return {
      'kind': kinds.contains(kind) ? kind : 'post',
      'reporterUid': reporterUid,
      'reporterUsername': cut(reporterUsername, 40),
      'targetId': cut(targetId, 128),
      'postId': cut(postId, 128),
      'targetUid': cut(targetUid, 128),
      'reason': cut(reason, 80),
      'message': cut(message.trim(), 2000),
    };
  }

  /// Saves a report for the admin (never throws; the email still works).
  /// v0.20: then Hyper Intelligence counts it (3 points = blurred,
  /// 6 = hidden, child safety = hidden at once).
  Future<void> save(Map<String, dynamic> data) async {
    if ((data['reporterUid'] as String? ?? '').isEmpty) return;
    try {
      final ref = await FirebaseFirestore.instance
          .collection('reports')
          .add({...data, 'createdAt': FieldValue.serverTimestamp()})
          .timeout(const Duration(seconds: 10));
      if (data['kind'] != 'user') {
        await ApiClient.instance.post('/api/hi', {
          'action': 'report',
          'reportId': ref.id,
        });
      }
    } catch (e) {
      debugPrint('report save: $e');
    }
  }

  /// Email for reporting a post / clip.
  static ReportEmail postEmail({
    required Post post,
    required String reason,
    required String message,
    String reporterUsername = '',
    String reporterUid = '',
  }) {
    final what = post.isClip ? 'Clip' : 'Post';
    final caption = post.caption.length > 300
        ? '${post.caption.substring(0, 300)}…'
        : post.caption;
    return ReportEmail(
      'Report: $what by @${post.authorUsername} — $reason',
      [
        'Reason: $reason',
        '',
        'Message:',
        message.trim(),
        '',
        '---- Details (please keep) ----',
        '$what ID: ${post.id}',
        'Author: @${post.authorUsername} (${post.authorId})',
        'Media: ${post.mediaUrl}',
        if (caption.isNotEmpty) 'Caption: $caption',
        if (reporterUsername.isNotEmpty)
          'Reported by: @$reporterUsername ($reporterUid)',
        'App version: ${AppInfo.version}',
      ].join('\n'),
    );
  }

  /// v0.11: email for reporting a comment.
  static ReportEmail commentEmail({
    required Post post,
    required Comment comment,
    String reporterUsername = '',
    String reporterUid = '',
  }) {
    final what = post.isClip ? 'Clip' : 'Post';
    final text = comment.text.length > 500
        ? '${comment.text.substring(0, 500)}…'
        : comment.text;
    return ReportEmail(
      'Report: comment by @${comment.authorUsername}',
      [
        'Message:',
        'This comment breaks the rules.',
        '',
        '---- Details (please keep) ----',
        'Comment ID: ${comment.id}',
        'Comment by: @${comment.authorUsername} (${comment.authorId})',
        if (text.isNotEmpty) 'Comment: $text',
        if (comment.imageUrl.isNotEmpty) 'Photo: ${comment.imageUrl}',
        if (comment.gifUrl.isNotEmpty) 'GIF: ${comment.gifUrl}',
        '$what ID: ${post.id} (by @${post.authorUsername})',
        if (reporterUsername.isNotEmpty)
          'Reported by: @$reporterUsername ($reporterUid)',
        'App version: ${AppInfo.version}',
      ].join('\n'),
    );
  }

  /// Email for reporting an account.
  static ReportEmail userEmail({
    required UserProfile user,
    required String message,
    String reporterUsername = '',
    String reporterUid = '',
  }) {
    return ReportEmail(
      'Report: account @${user.username}',
      [
        'Message:',
        message.trim(),
        '',
        '---- Details (please keep) ----',
        'Account: @${user.username} (${user.uid})',
        if (reporterUsername.isNotEmpty)
          'Reported by: @$reporterUsername ($reporterUid)',
        'App version: ${AppInfo.version}',
      ].join('\n'),
    );
  }
}
