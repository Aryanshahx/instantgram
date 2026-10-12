class AppConstants {
  AppConstants._();

  static const String appName = 'InstantGram';
  static const String profileLinkBase = 'https://instantgram.app/@';

  /// Vercel backend URL — filled in later.
  /// Can be passed at build time: --dart-define=API_BASE_URL=https://xyz.vercel.app
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: '',
  );
}
