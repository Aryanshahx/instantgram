import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/models/app_user.dart';
import 'package:instantgram/screens/profile/edit_profile_screen.dart';
import 'package:instantgram/widgets/avatar.dart';

void main() {
  group('normalizeLink', () {
    test('adds https and accepts normal addresses', () {
      expect(normalizeLink('example.com'), 'https://example.com');
      expect(normalizeLink(' www.site.in/me '), 'https://www.site.in/me');
      expect(normalizeLink('http://a.io/x?y=1'), 'http://a.io/x?y=1');
    });
    test('rejects things that are not web addresses', () {
      expect(normalizeLink(''), isNull);
      expect(normalizeLink('hello'), isNull);
      expect(normalizeLink('two words.com'), isNull);
      expect(normalizeLink('javascript://x.y'), isNull);
      expect(normalizeLink('ftp://files.example.com'), isNull);
    });
  });

  testWidgets('the default profile picture is a silhouette, not a letter', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: UserAvatar(url: '', name: 'zoe', radius: 40),
          ),
        ),
      ),
    );
    expect(find.text('Z'), findsNothing);
    expect(find.text('?'), findsNothing);
    expect(find.byType(UserAvatar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(360, 640), Size(411, 891), Size(1000, 700)]) {
    testWidgets(
      'edit profile fits ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          const MaterialApp(
            home: EditProfileScreen(
              user: AppUser(
                uid: 'u1',
                username: 'aryan',
                fullName: 'Aryan',
                bio: 'hello',
                links: ['https://example.com'],
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Username', skipOffstage: false), findsOneWidget);
        expect(find.text('Add banner'), findsOneWidget);
        expect(
          find.text('Link 1 address', skipOffstage: false),
          findsOneWidget,
        );
        expect(find.text('Link 1 name', skipOffstage: false), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Save changes'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
