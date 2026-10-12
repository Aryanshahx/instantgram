import 'api_url.dart';

class AppConfig {
  AppConfig._();

  /// Set by GitHub Actions: --dart-define=API_BASE_URL=https://xxx.vercel.app
  static const String _fromBuild = String.fromEnvironment('API_BASE_URL');

  /// Vercel backend URL (no trailing slash).
  static String get apiBaseUrl {
    final url = _fromBuild.isNotEmpty ? _fromBuild : kDefaultApiBaseUrl;
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  static bool get hasApi => apiBaseUrl.startsWith('http');
}
