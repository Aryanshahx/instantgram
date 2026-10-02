import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instantgram/core/theme.dart';
import 'package:instantgram/screens/auth/login_screen.dart';
import 'package:instantgram/screens/auth/signup_screen.dart';
import 'package:instantgram/widgets/avatar.dart';
import 'package:instantgram/widgets/brand_logo.dart';
import 'package:instantgram/widgets/pill_tabs.dart';
import 'package:instantgram/widgets/state_views.dart';

Widget _app(Widget child, ThemeData theme) =>
    MaterialApp(theme: theme, home: child);

void main() {
  for (final entry in {'light': AppTheme.light, 'dark': AppTheme.dark}.entries) {
    group('Volt UI (${entry.key})', () {
      testWidgets('login screen renders without layout errors', (t) async {
        t.view.physicalSize = const Size(1080, 2000);
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        await t.pumpWidget(_app(const LoginScreen(), entry.value));
        await t.pump(const Duration(milliseconds: 300));
        expect(find.text('Log in'), findsOneWidget);
        expect(find.textContaining('instantly'), findsOneWidget);
        expect(t.takeException(), isNull);
      });

      testWidgets('signup screen renders on a small phone', (t) async {
        t.view.physicalSize = const Size(720, 1280);
        t.view.devicePixelRatio = 2;
        addTearDown(t.view.reset);
        await t.pumpWidget(_app(const SignupScreen(), entry.value));
        await t.pump(const Duration(milliseconds: 300));
        expect(find.text('Create account'), findsOneWidget);
        expect(t.takeException(), isNull);
      });

      testWidgets('shared widgets render', (t) async {
        var tab = 0;
        await t.pumpWidget(_app(
          Scaffold(
            body: StatefulBuilder(
              builder: (context, set) => Column(
                children: [
                  const BrandLogo(size: 28),
                  const UserAvatar(url: '', name: 'aryan', radius: 30, ring: true),
                  PillTabs(
                    labels: const ['Discover', 'Following'],
                    index: tab,
                    onChanged: (i) => set(() => tab = i),
                  ),
                  const Expanded(
                    child: EmptyState(icon: Icons.bolt_rounded, title: 'Empty'),
                  ),
                ],
              ),
            ),
          ),
          entry.value,
        ));
        await t.tap(find.text('Following'));
        await t.pump(const Duration(milliseconds: 400));
        expect(tab, 1);
        expect(find.text('Empty'), findsOneWidget);
        expect(t.takeException(), isNull);
      });
    });
  }
}
