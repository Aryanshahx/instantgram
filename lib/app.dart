import 'package:flutter/material.dart';

import 'core/constants/app_constants.dart';
import 'core/navigation/page_cover.dart';
import 'core/services/calls.dart';
import 'core/services/app_settings.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/presentation/auth_gate.dart';

class InstantGramApp extends StatelessWidget {
  const InstantGramApp({super.key, this.home});

  /// Override the first screen (used in tests).
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      // v0.9: call screens open on this navigator
      navigatorKey: Calls.instance.navigatorKey,
      theme: AppTheme.dark,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      // Settings → Accessibility: text size + reduce motion
      builder: (context, child) => ListenableBuilder(
        listenable: Listenable.merge([s.textScale, s.reduceMotion]),
        builder: (context, _) {
          final mq = MediaQuery.of(context);
          final system = mq.textScaler.scale(100) / 100;
          return MediaQuery(
            data: mq.copyWith(
              textScaler: TextScaler.linear(
                (system * s.textScale.value).clamp(0.8, 2.0),
              ),
              disableAnimations: mq.disableAnimations || s.reduceMotion.value,
            ),
            child: child ?? const SizedBox.shrink(),
          );
        },
      ),
      // v0.8: videos pause while another page is open on top
      navigatorObservers: [PageCover.instance],
      home: home ?? const AuthGate(),
    );
  }
}
