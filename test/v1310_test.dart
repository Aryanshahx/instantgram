import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/errors.dart';
import 'package:instantgram/core/mod_words.dart';
import 'package:instantgram/services/app_prefs.dart';
import 'package:instantgram/services/moderation.dart';
import 'package:instantgram/services/rate_limits.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final mod = Moderation.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppPrefs.instance.init();
    mod.apply();
    RateLimits.instance.reset();
    RateLimits.instance.now = DateTime.now;
  });

  group('word filter', () {
    test('tricks are seen through', () {
      final f = mod.filter;
      expect(normalizeToken('5H1T'), 'shit');
      for (final t in [
        'fuck', 'FUCK', 'fuuuuck', 'f*ck', 'fu*k', 'f u c k', 'f.u.c.k', //
        'fucking', 'motherfucker', '#fuck', 'sh!t', r'$hit',
      ]) {
        expect(f.scan(t).clean, isFalse, reason: t);
      }
      for (final t in [
        'as', 'pass', 'class', 'assess', 'grape', 'cocktail', 'Gandhi', //
        'hello world', 'f***', 's***', 'a b c', 'scunthorpe', '@assam',
      ]) {
        expect(f.scan(t).clean, isTrue, reason: t);
      }
    });

    test('swear words are starred, blocked words stop the post', () {
      expect(mod.publicText('what the fuck bro'), 'what the f*** bro');
      expect(mod.publicText('nice pic'), 'nice pic');
      expect(
        () => mod.publicText('madarchod', what: 'caption'),
        throwsA(
          isA<ModerationException>().having(
            (e) => e.message,
            'message',
            contains('caption'),
          ),
        ),
      );
      expect(
        () => mod.publicText('just kill yourself'),
        throwsA(isA<ModerationException>()),
      );
      expect(
        () => mod.publicText('मादरचोद'),
        throwsA(isA<ModerationException>()),
      );
      expect(friendlyError(const ModerationException('x')), 'x');
    });

    test('usernames and names may have no bad words at all', () {
      expect(
        () => mod.checkName('fuck_boi'),
        throwsA(isA<ModerationException>()),
      );
      expect(
        () => mod.checkName('chutiya.99'),
        throwsA(isA<ModerationException>()),
      );
      mod.checkName('aryan_shah');
      mod.checkName('classic.pass');
    });

    test('chats only star blocked words', () {
      expect(mod.chatText('shit happens'), 'shit happens');
      expect(mod.chatText('you madarchod'), startsWith('you m*'));
    });

    test('the panel lists add and allow words', () {
      mod.apply(blocked: ['scamlink'], mild: ['meanie'], allow: ['ass']);
      expect(
        () => mod.publicText('visit scamlink'),
        throwsA(isA<ModerationException>()),
      );
      expect(mod.publicText('meanie'), 'm*****');
      expect(mod.publicText('ass'), 'ass');
    });

    test('the app and the signer use the same default lists', () {
      final j =
          jsonDecode(File('signer/lib/mod_words.json').readAsStringSync())
              as Map;
      expect(kBlockedWords, (j['blocked'] as List).cast<String>());
      expect(kMildWords, (j['mild'] as List).cast<String>());
    });
  });

  group('spam limits', () {
    test('comments: 30 an hour and no copy-paste', () {
      var t = DateTime(2026, 10, 10, 10);
      final r = RateLimits.instance..now = () => t;
      r.comment('u1', 'nice');
      r.comment('u1', 'Nice ');
      expect(() => r.comment('u1', 'nice'), throwsA(isA<RateLimitException>()));
      for (var i = 0; i < 28; i++) {
        r.comment('u1', 'comment $i');
      }
      expect(
        () => r.comment('u1', 'one more'),
        throwsA(isA<RateLimitException>()),
      );
      t = t.add(const Duration(hours: 1, minutes: 1));
      r.comment('u1', 'nice'); // an hour later it is fine again
    });

    test('follows: 20 a minute', () {
      var t = DateTime(2026, 10, 10, 10);
      final r = RateLimits.instance..now = () => t;
      for (var i = 0; i < 20; i++) {
        r.follow('u1');
      }
      expect(() => r.follow('u1'), throwsA(isA<RateLimitException>()));
      t = t.add(const Duration(seconds: 61));
      r.follow('u1');
    });

    test('uploads: 10 a day for new accounts, 50 for others', () {
      final t = DateTime(2026, 10, 10, 10);
      final r = RateLimits.instance..now = () => t;
      final young = t.subtract(const Duration(days: 2));
      for (var i = 0; i < 10; i++) {
        r.upload('new1', young);
      }
      expect(() => r.upload('new1', young), throwsA(isA<RateLimitException>()));
      final old = t.subtract(const Duration(days: 90));
      for (var i = 0; i < 50; i++) {
        r.upload('old1', old);
      }
      expect(() => r.upload('old1', old), throwsA(isA<RateLimitException>()));
    });

    test('limits survive an app restart', () {
      final t = DateTime(2026, 10, 10, 10);
      RateLimits.instance.now = () => t;
      for (var i = 0; i < 20; i++) {
        RateLimits.instance.follow('u2');
      }
      expect(AppPrefs.instance.rateLog, contains('follow:u2'));
    });
  });

  test('rules keep the review queue private', () {
    final r = File('firebase/firestore.rules').readAsStringSync();
    expect(r, contains('match /modQueue/{id}'));
    final h = File('signer/lib/panel.html').readAsStringSync();
    expect(h, contains('data-tab="review"'));
    expect(h, contains('id="wBlocked"'));
  });
}
