import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/config/app_config.dart';
import 'package:instantgram/core/utils/errors.dart';
import 'package:instantgram/features/shell/widgets/floating_nav_bar.dart';

const _items = [
  NavItem('Discover', Icons.home_outlined, Icons.home_rounded),
  NavItem('Explore', Icons.explore_outlined, Icons.explore),
  NavItem('Clips', Icons.play_circle_outline, Icons.play_circle),
  NavItem('Chats', Icons.chat_bubble_outline, Icons.chat_bubble),
  NavItem('Me', Icons.person_outline, Icons.person),
];

Widget _bar(int index) => MaterialApp(
  theme: ThemeData(fontFamily: 'Inter'),
  home: Scaffold(
    bottomNavigationBar: FloatingNavBar(
      items: _items,
      currentIndex: index,
      onTap: (_) {},
      onCreate: () {},
    ),
  ),
);

Future<void> _loadInter() async {
  final loader = FontLoader('Inter');
  for (final w in [400, 700]) {
    final bytes = File('assets/fonts/Inter-$w.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

void main() {
  setUpAll(_loadInter);
  for (final width in [320.0, 360.0, 411.0]) {
    for (final index in [0, 1, 3, 4]) {
      testWidgets('nav shows full "${_items[index].label}" at ${width}dp', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width * 3, 800 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_bar(index));
        await tester.pumpAndSettle();

        final label = find.text(_items[index].label);
        expect(label, findsOneWidget);
        // Text must not be clipped: painted width == wanted width.
        final para = tester.renderObject<RenderParagraph>(label);
        expect(para.didExceedMaxLines, isFalse);
        expect(
          para.size.width,
          greaterThanOrEqualTo(para.getMaxIntrinsicWidth(100) - 0.5),
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  test('friendly errors', () {
    expect(
      friendlyError(
        '[cloud_firestore/failed-precondition] The query requires an index',
      ),
      contains('setting up'),
    );
    expect(friendlyError('[x/permission-denied] nope'), contains('Permission'));
  });

  test('api url has no trailing slash', () {
    expect(AppConfig.apiBaseUrl.endsWith('/'), isFalse);
  });
}
