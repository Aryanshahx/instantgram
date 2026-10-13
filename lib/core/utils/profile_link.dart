import '../config/app_config.dart';

/// Profile links (v0.7):
///  * web:  `https://<your-vercel-app>/u/<username>` (page with "Open app")
///  * app:  `instantgram://u/<username>`
const String kAppScheme = 'instantgram';

final RegExp _username = RegExp(r'^[a-z0-9._]{3,30}$');

/// Link people can open anywhere (QR codes, copy, share).
String profileLink(String username) => AppConfig.hasApi
    ? '${AppConfig.apiBaseUrl}/u/$username'
    : '$kAppScheme://u/$username';

/// Username inside a profile link / QR code, or null when it is not one.
/// Accepts the web link, the app link and "@username".
String? usernameFromLink(String raw) {
  final text = raw.trim();
  if (text.startsWith('@')) return _clean(text.substring(1));
  final uri = Uri.tryParse(text);
  if (uri == null) return null;
  final seg = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (uri.scheme == kAppScheme) {
    // instantgram://u/name  (host = "u")
    if (uri.host == 'u' && seg.isNotEmpty) return _clean(seg.first);
    if (seg.length >= 2 && seg.first == 'u') return _clean(seg[1]);
    return null;
  }
  if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      seg.length >= 2 &&
      seg.first == 'u') {
    return _clean(seg[1]);
  }
  return null;
}

String? _clean(String s) {
  final n = s.trim().toLowerCase();
  return _username.hasMatch(n) ? n : null;
}
