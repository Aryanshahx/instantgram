import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'app_settings.dart';

/// Catches app errors:
///  * a broken widget shows a small dark box with the reason
///    (instead of Flutter's grey box that looks white on a dark screen)
///  * errors are saved to Settings → About → Error log
class ErrorReporter {
  ErrorReporter._();

  static bool _installed = false;

  static void install() {
    if (_installed) return;
    _installed = true;
    ErrorWidget.builder = (details) => BrokenWidget(details: details);
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      _log(details.exceptionAsString(), details.stack);
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _log(error.toString(), stack);
      return true; // handled: keep the app running
    };
  }

  static void _log(String message, StackTrace? stack) {
    final where = stack == null ? '' : _firstAppFrame(stack);
    AppSettings.instance.logError(where.isEmpty ? message : '$message\n$where');
  }

  /// First stack line from our own code (shorter, more useful).
  static String _firstAppFrame(StackTrace stack) {
    for (final line in stack.toString().split('\n')) {
      if (line.contains('package:instantgram/')) return line.trim();
    }
    return '';
  }
}

/// Shown in place of a widget that crashed.
class BrokenWidget extends StatelessWidget {
  const BrokenWidget({super.key, required this.details});
  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    final msg = details.exceptionAsString();
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF15171E),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Color(0xFFFF6B6B),
                  size: 26,
                ),
                const SizedBox(height: 6),
                const Text(
                  'Something went wrong here',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFFF2F3F5),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  msg.length > 300 ? '${msg.substring(0, 300)}…' : msg,
                  textAlign: TextAlign.center,
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF9A9DA6),
                    fontSize: 11,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
