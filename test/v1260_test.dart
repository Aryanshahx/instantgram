import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/fonts.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/models/app_user.dart';
import 'package:instantgram/models/chat.dart';
import 'package:instantgram/screens/profile/edit_profile_screen.dart';
import 'package:instantgram/screens/settings/app_icon_screen.dart';
import 'package:instantgram/services/app_icon_service.dart';
import 'package:instantgram/widgets/font_picker.dart';
import 'package:instantgram/widgets/message_bubble.dart';

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.dark,
  home: Scaffold(body: child),
);

const _channel = MethodChannel('instantgram/app_icon');

void main() {
  group('fonts for bios and messages', () {
    test("'' and unknown ids keep the normal text", () {
      const base = TextStyle(fontSize: 15, fontWeight: FontWeight.w500);
      expect(maybeAppFont('', base), base);
      expect(maybeAppFont('from-the-future', base), base);
      expect(maybeAppFont('marker', base).fontFamily, 'Marker');
      expect(maybeAppFont('marker', base).fontSize, 15);
    });

    testWidgets('a message is shown in its font', (t) async {
      await t.pumpWidget(
        _app(
          MessageBubble(
            mine: false,
            time: '12:00',
            message: ChatMessage(
              id: 'm',
              senderId: 'zoe',
              text: 'hello there',
              createdAt: DateTime(2026),
              font: 'lobster',
            ),
          ),
        ),
      );
      final txt = t.widget<Text>(find.text('hello there'));
      expect(txt.style?.fontFamily, 'Lobster');
    });

    testWidgets('chips: each in its own font, tap picks', (t) async {
      var picked = '';
      await t.pumpWidget(
        _app(
          FontChipRow(
            selected: '',
            keyPrefix: 'x',
            onChanged: (f) => picked = f,
          ),
        ),
      );
      expect(find.text('Normal'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('x_marker')));
      expect(picked, 'marker');
    });

    testWidgets('edit profile: the bio takes the picked font', (t) async {
      await t.binding.setSurfaceSize(const Size(500, 1400));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const EditProfileScreen(
            user: AppUser(
              uid: 'me',
              username: 'me',
              bio: 'hi',
              bioFont: 'hand',
            ),
          ),
        ),
      );
      await _settle(t);
      TextField bio() => t.widget<TextField>(
        find.ancestor(of: find.text('hi'), matching: find.byType(TextField)),
      );
      expect(bio().style?.fontFamily, 'Caveat');
      await t.ensureVisible(find.byKey(const ValueKey('bioFont_marker')));
      await t.tap(find.byKey(const ValueKey('bioFont_marker')));
      await t.pump();
      expect(bio().style?.fontFamily, 'Marker');
    });
  });

  group('app icon', () {
    late List<MethodCall> calls;
    late bool available;
    late String current;
    setUp(() {
      calls = [];
      available = true;
      current = 'classic';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (c) async {
            calls.add(c);
            switch (c.method) {
              case 'available':
                return available;
              case 'get':
                return current;
              case 'set':
                current = (c.arguments as Map)['id'] as String;
                return current;
            }
            return null;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });

    test('six icons, unknown ones refused', () async {
      expect(kAppIcons.length, 6);
      expect(kAppIcons.first.id, 'classic');
      expect(() => AppIconService.instance.set('rainbow'), throwsArgumentError);
      current = 'nonsense';
      expect(await AppIconService.instance.current(), 'classic');
    });

    testWidgets('pick another icon', (t) async {
      current = 'sunset';
      await t.pumpWidget(const MaterialApp(home: AppIconScreen()));
      await _settle(t);
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('icon_ocean')));
      await _settle(t);
      expect(current, 'ocean');
      expect(calls.where((c) => c.method == 'set').single.arguments, {
        'id': 'ocean',
      });
      expect(find.textContaining('Icon changed to Ocean'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('a build without the icons says so', (t) async {
      available = false;
      await t.pumpWidget(const MaterialApp(home: AppIconScreen()));
      await _settle(t);
      expect(find.textContaining('newest app build'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('icon_gold')));
      await _settle(t);
      expect(calls.where((c) => c.method == 'set'), isEmpty);
    });
  });
}
