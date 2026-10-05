import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'core/a11y.dart';
import 'core/l10n.dart';
import 'services/app_prefs.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await AppPrefs.instance.init();
  Language.instance.load();
  A11y.instance.load();
  runApp(const InstantgramApp());
}
