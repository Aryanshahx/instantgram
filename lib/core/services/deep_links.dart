import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import '../utils/profile_link.dart';

/// Opens profiles from links: `instantgram://u/<username>` (from the web
/// page of a shared profile link or a QR code).
class DeepLinks {
  DeepLinks._();
  static final DeepLinks instance = DeepLinks._();

  /// Tests switch this off (no plugin).
  static bool disabled = false;

  StreamSubscription<Uri>? _sub;

  void start(void Function(String username) onProfile) {
    if (disabled || kIsWeb || _sub != null) return;
    try {
      _sub = AppLinks().uriLinkStream.listen((uri) {
        final name = usernameFromLink(uri.toString());
        if (name != null) onProfile(name);
      }, onError: (Object e) => debugPrint('deep link: $e'));
    } catch (e) {
      debugPrint('deep links off: $e');
    }
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }
}
