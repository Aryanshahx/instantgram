import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/models/chat.dart';
import 'package:instantgram/screens/settings/push_settings_screen.dart';
import 'package:instantgram/services/push_service.dart';

void main() {
  test('pin and mute belong to each person; old shared true still counts', () {
    expect(ChatThread.flagFor({'a': true}, 'a'), isTrue);
    expect(ChatThread.flagFor({'a': true}, 'b'), isFalse);
    expect(ChatThread.flagFor({'a': false, 'b': true}, 'a'), isFalse);
    expect(ChatThread.flagFor(true, 'b'), isTrue);
    expect(ChatThread.flagFor(false, 'a'), isFalse);
    expect(ChatThread.flagFor(null, 'a'), isFalse);
  });

  test('push requests carry only ids (the server writes the text)', () async {
    final sent = <Map<String, dynamic>>[];
    PushService.instance.sendBackend = (b) async => sent.add(b);
    addTearDown(() => PushService.instance.sendBackend = null);
    PushService.instance.message('a_b', 'm1');
    PushService.instance.call('c1');
    PushService.instance.activity('b', 'n1');
    await Future<void>.delayed(Duration.zero);
    expect(sent, [
      {'kind': 'message', 'chatId': 'a_b', 'messageId': 'm1'},
      {'kind': 'call', 'callId': 'c1'},
      {'kind': 'activity', 'to': 'b', 'itemId': 'n1'},
    ]);
  });

  test('a failing push never throws into the sender', () async {
    PushService.instance.sendBackend = (b) async => throw Exception('offline');
    addTearDown(() => PushService.instance.sendBackend = null);
    PushService.instance.message('a_b', 'm1');
    await Future<void>.delayed(Duration.zero);
  });

  test('without Firebase (tests) start and stop do nothing', () async {
    await PushService.instance.start();
    await PushService.instance.stop();
    expect(await PushService.instance.isOff(), isFalse);
  });

  testWidgets('Notifications settings show the push switch', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PushSettingsScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('pushSwitch')), findsOneWidget);
    expect(find.text('Push notifications'), findsOneWidget);
    final sw = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('pushSwitch')),
    );
    expect(sw.value, isTrue);
  });
}
