import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../shell/main_shell.dart';
import '../../splash/presentation/splash_screen.dart';
import '../data/auth_service.dart';
import 'login_screen.dart';

/// Shows Login when signed out, the main app when signed in.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: AuthService.instance.authStateChanges(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const SplashScreen();
        }
        final user = snap.data;
        if (user == null) return const LoginScreen();
        return MainShell(key: ValueKey(user.uid), uid: user.uid);
      },
    );
  }
}
