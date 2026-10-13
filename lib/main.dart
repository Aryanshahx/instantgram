import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/services/media_service.dart';
import 'core/services/app_settings.dart';
import 'core/services/error_reporter.dart';
import 'core/services/video_cache.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  useSystemPhotoPicker();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await AppSettings.instance.load(); // text size, language, history…
  ErrorReporter.install(); // readable error boxes + Error log
  // v0.8: videos are saved on the phone while they play (watch again =
  // no new download)
  unawaited(VideoCache.instance.start());

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  runApp(const InstantGramApp());
}
