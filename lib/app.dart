import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'screens/auth/auth_gate.dart';

class InstantgramApp extends StatelessWidget {
  const InstantgramApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Instantgram',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const AuthGate(),
    );
  }
}
