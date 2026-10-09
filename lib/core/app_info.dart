/// The version shown in Settings. Keep it in step with pubspec.yaml's version name.
const String kAppVersion = '1.31.0';

const String kAppName = 'InstantGram';
const String kCompany = 'Hyper Tech Labs';
const String kSupportEmail = 'techlabs.hyper@gmail.com';

/// Where new versions are published (GitHub releases).
const String kReleasesApi =
    'https://api.github.com/repos/Aryanshahx/instantgram/releases/latest';
const String kReleasesPage =
    'https://github.com/Aryanshahx/instantgram/releases';

/// True when [latest] (like "v1.14.0" or "1.14.0") is newer than [current].
bool isNewerVersion(String latest, String current) {
  List<int> parts(String v) {
    final m = RegExp(r'(\d+)\.(\d+)(?:\.(\d+))?').firstMatch(v);
    if (m == null) return const [0, 0, 0];
    return [for (var i = 1; i <= 3; i++) int.tryParse(m.group(i) ?? '') ?? 0];
  }

  final a = parts(latest);
  final b = parts(current);
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}
