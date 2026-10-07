import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:instantgram/core/legal.dart';
import 'package:instantgram/core/legal_text.dart';

void main() {
  test('the pages on the web and the pages in the app say the same thing', () {
    for (final page in [
      ('privacy', kPrivacySections),
      ('terms', kTermsSections),
    ]) {
      final html = File('docs/${page.$1}.html').readAsStringSync();
      final md = File('docs/${page.$1}.md').readAsStringSync();
      expect(html, contains('InstantGram'));
      for (final section in page.$2) {
        expect(html, contains(section.$1), reason: '${page.$1}: ${section.$1}');
        expect(html, contains(section.$2));
        expect(md, contains(section.$1));
      }
    }
  });

  test('both pages say how an account is deleted', () {
    expect(
      kPrivacySections.where((s) => s.$1 == 'Deleting your account'),
      hasLength(1),
    );
    expect(
      kTermsSections.where((s) => s.$1 == 'Deleting your account'),
      hasLength(1),
    );
    final how = kPrivacySections
        .firstWhere((s) => s.$1 == 'Deleting your account')
        .$2;
    expect(how, contains('6 digit code'));
    expect(how, contains('Firebase Authentication'));
    expect(how, contains('up to 30 days'));
    expect(how, contains('techlabs.hyper@gmail.com'));
  });

  test('the pages are never empty, and the app links to the ones on the web', () {
    expect(kPrivacySections.length, greaterThan(8));
    expect(kTermsSections.length, greaterThan(6));
    for (final section in [...kPrivacySections, ...kTermsSections]) {
      expect(section.$1.trim(), isNotEmpty);
      expect(section.$2.length, greaterThan(40));
    }
    // the pages the app opens are the files in the repository
    expect(kPrivacyUrl, '$kRepoBaseUrl/privacy.md');
    expect(kTermsUrl, '$kRepoBaseUrl/terms.md');
    expect(File('docs/privacy.html').existsSync(), isTrue);
    expect(File('docs/terms.html').existsSync(), isTrue);
    // Pages must not build the files with Jekyll: they are complete pages already.
    expect(File('docs/.nojekyll').existsSync(), isTrue);
  });

  test('the old music name is not used anywhere in the legal text', () {
    final all = [
      ...kPrivacySections,
      ...kTermsSections,
    ].map((s) => '${s.$1} ${s.$2}').join('\n').toLowerCase();
    expect(all, isNot(contains('epidemic')));
    expect(all, contains('jamendo'));
    expect(all, contains('openverse'));
  });
}
