import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/utils/time_ago.dart';
import 'package:instantgram/features/post/data/report_repository.dart';

void main() {
  test('report templates use clip / post', () {
    final spam = kReportReasons.first;
    expect(spam.title, 'Spam');
    expect(spam.message('clip'), 'This clip is spam or misleading.');
    expect(spam.message('post'), 'This post is spam or misleading.');
    // "Something else" lets the user write their own text
    expect(kReportReasons.last.message('clip'), isEmpty);
    for (final r in kReportReasons) {
      expect(r.title.length, lessThanOrEqualTo(60)); // database rule limit
    }
  });

  test('full date', () {
    expect(fullDate(DateTime(2026, 10, 12, 17, 5)), '12 Oct 2026, 5:05 PM');
    expect(fullDate(DateTime(2026, 1, 3, 0, 30)), '3 Jan 2026, 12:30 AM');
    expect(fullDate(DateTime(2026, 6, 1, 12, 0)), '1 Jun 2026, 12:00 PM');
  });
}
