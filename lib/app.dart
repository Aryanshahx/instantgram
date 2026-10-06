import 'package:flutter/material.dart';

import 'core/a11y.dart';
import 'core/l10n.dart';
import 'core/theme.dart';
import 'screens/auth/auth_gate.dart';
import 'widgets/hold_haptics.dart';

class InstantgramApp extends StatelessWidget {
  const InstantgramApp({super.key});

  @override
  Widget build(BuildContext context) {
    return LanguageScope(
      language: Language.instance,
      child: ListenableBuilder(
        listenable: A11y.instance,
        builder: (context, _) => MaterialApp(
          title: 'InstantGram',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: A11y.instance.themeMode,
          builder: (context, child) {
            final a = A11y.instance;
            final mq = MediaQuery.of(context);
            return HoldHaptics(
              child: MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(
                  mq.textScaler.scale(1) * a.textScale,
                ),
                boldText: mq.boldText || a.boldText,
                disableAnimations: mq.disableAnimations || a.reduceMotion,
              ),
              child: ValueListenableBuilder<String>(
                valueListenable: Language.instance,
                builder: (context, _, inner) => Directionality(
                  textDirection: Language.instance.isRtl
                      ? TextDirection.rtl
                      : TextDirection.ltr,
                  child: inner!,
                ),
                child: child ?? const SizedBox.shrink(),
              ),
            ),
            );
          },
          home: const AuthGate(),
        ),
      ),
    );
  }
}
