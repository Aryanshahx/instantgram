import 'package:flutter/material.dart';

import '../data/user_repository.dart';
import 'profile_screen.dart';

/// Looks up @[username] and opens the profile (or says it was not found).
/// [replace] = the profile replaces the current page (QR scanner).
Future<bool> openUsername(
  BuildContext context,
  String username, {
  bool replace = false,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final nav = Navigator.of(context);
  try {
    final user = await UserRepository.instance.userByUsername(username);
    if (user == null) {
      messenger?.showSnackBar(
        SnackBar(content: Text('No account called @$username')),
      );
      return false;
    }
    final route = MaterialPageRoute<void>(
      builder: (_) => ProfileScreen(uid: user.uid, standalone: true),
    );
    if (replace) {
      nav.pushReplacement(route);
    } else {
      nav.push(route);
    }
    return true;
  } catch (_) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('Could not open the profile. Try again.')),
    );
    return false;
  }
}
