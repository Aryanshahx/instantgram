/// App facts shown in Settings (version is updated by the update scripts).
class AppInfo {
  AppInfo._();

  static const String version = '0.0.1';

  /// v0.0.1: Hyper Intelligence has the same version as the app.
  static const String hiVersion = version;
  static const String supportEmail = 'techlabs.hyper@gmail.com';
  static const String company = 'HyperTech Labs';

  /// GitHub repo (legal pages).
  static const String githubRepo = 'Aryanshahx/instantgram';

  /// Legal pages (files in the GitHub repo).
  static const String privacyPolicyUrl =
      'https://github.com/$githubRepo/blob/main/privacypolicy.md';
  static const String termsUrl =
      'https://github.com/$githubRepo/blob/main/termsofuse.md';
}

/// "0.4.0" < "0.4.1"  (ignores a leading "v" and "+build")
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .trim()
      .replaceFirst(RegExp(r'^[vV]'), '')
      .split('+')
      .first
      .split('.')
      .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final m = i < x.length ? x[i] : 0;
    final n = i < y.length ? y[i] : 0;
    if (m != n) return m < n ? -1 : 1;
  }
  return 0;
}
