/// Languages users can pick (sign up + Settings → Language).
class AppLanguage {
  const AppLanguage(this.code, this.name, this.native);
  final String code;
  final String name;
  final String native;

  String get label => name == native ? name : '$name · $native';
}

const List<AppLanguage> kLanguages = [
  AppLanguage('en', 'English', 'English'),
  AppLanguage('hi', 'Hindi', 'हिन्दी'),
  AppLanguage('bn', 'Bengali', 'বাংলা'),
  AppLanguage('te', 'Telugu', 'తెలుగు'),
  AppLanguage('mr', 'Marathi', 'मराठी'),
  AppLanguage('ta', 'Tamil', 'தமிழ்'),
  AppLanguage('ur', 'Urdu', 'اردو'),
  AppLanguage('gu', 'Gujarati', 'ગુજરાતી'),
  AppLanguage('kn', 'Kannada', 'ಕನ್ನಡ'),
  AppLanguage('ml', 'Malayalam', 'മലയാളം'),
  AppLanguage('pa', 'Punjabi', 'ਪੰਜਾਬੀ'),
  AppLanguage('or', 'Odia', 'ଓଡ଼ିଆ'),
  AppLanguage('as', 'Assamese', 'অসমীয়া'),
  AppLanguage('ne', 'Nepali', 'नेपाली'),
  AppLanguage('si', 'Sinhala', 'සිංහල'),
  AppLanguage('es', 'Spanish', 'Español'),
  AppLanguage('fr', 'French', 'Français'),
  AppLanguage('de', 'German', 'Deutsch'),
  AppLanguage('it', 'Italian', 'Italiano'),
  AppLanguage('pt', 'Portuguese', 'Português'),
  AppLanguage('nl', 'Dutch', 'Nederlands'),
  AppLanguage('pl', 'Polish', 'Polski'),
  AppLanguage('uk', 'Ukrainian', 'Українська'),
  AppLanguage('ru', 'Russian', 'Русский'),
  AppLanguage('tr', 'Turkish', 'Türkçe'),
  AppLanguage('el', 'Greek', 'Ελληνικά'),
  AppLanguage('sv', 'Swedish', 'Svenska'),
  AppLanguage('ro', 'Romanian', 'Română'),
  AppLanguage('ar', 'Arabic', 'العربية'),
  AppLanguage('fa', 'Persian', 'فارسی'),
  AppLanguage('he', 'Hebrew', 'עברית'),
  AppLanguage('sw', 'Swahili', 'Kiswahili'),
  AppLanguage('zh', 'Chinese', '中文'),
  AppLanguage('ja', 'Japanese', '日本語'),
  AppLanguage('ko', 'Korean', '한국어'),
  AppLanguage('id', 'Indonesian', 'Bahasa Indonesia'),
  AppLanguage('ms', 'Malay', 'Bahasa Melayu'),
  AppLanguage('th', 'Thai', 'ไทย'),
  AppLanguage('vi', 'Vietnamese', 'Tiếng Việt'),
  AppLanguage('fil', 'Filipino', 'Filipino'),
];

AppLanguage? languageByCode(String code) {
  for (final l in kLanguages) {
    if (l.code == code) return l;
  }
  return null;
}
