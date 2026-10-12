import 'package:flutter/material.dart';

import '../../../core/config/app_info.dart';
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
  ReportReason('Something else', Icons.more_horiz, ''),
];

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
