class AppConstants {
  AppConstants._();

  static const String appName = 'InstantGram';

  /// Vercel backend URL — filled in later.
  /// --dart-define=API_BASE_URL=https://xyz.vercel.app
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: '',
  );
}
