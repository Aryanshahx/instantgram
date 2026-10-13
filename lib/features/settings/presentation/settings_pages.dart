import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/app_info.dart';
import '../../../core/constants/countries.dart';
import '../../../core/constants/languages.dart';
import '../../../core/services/app_settings.dart';
import '../../../core/services/media_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/email.dart';
import '../../../core/utils/errors.dart';
import '../../../core/utils/time_ago.dart';
import '../../../shared/models/user_profile.dart';
import '../../../shared/widgets/async_views.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/country_picker.dart';
import '../../../shared/widgets/ig_buttons.dart';
import '../../../shared/widgets/ig_logo.dart';
import '../../auth/data/auth_service.dart';
import '../../profile/data/user_repository.dart';
import '../../profile/presentation/edit_profile_screen.dart';
import 'settings_widgets.dart';

void _snack(BuildContext context, String msg) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(msg)));

// ============================================================== Account

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.profile});
  final UserProfile profile;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  late final Future<String> _dob = UserRepository.instance.birthDate();
  late String _country = widget.profile.country;

  UserProfile get p => widget.profile;

  Future<void> _changeCountry() async {
    final code = await showCountryPicker(context, current: _country);
    if (code == null || code == _country || !mounted) return;
    final old = _country;
    setState(() => _country = code);
    try {
      await UserRepository.instance.setCountry(code);
      if (mounted) _snack(context, 'Country updated');
    } catch (e) {
      if (!mounted) return;
      setState(() => _country = old);
      _snack(context, friendlyError(e));
    }
  }

  Future<void> _resetPassword() async {
    try {
      await AuthService.instance.sendPasswordReset(p.email);
      if (mounted) _snack(context, 'Password reset link sent to ${p.email}');
    } on AuthFailure catch (e) {
      if (mounted) _snack(context, e.message);
    }
  }

  Future<void> _changePhoto({required bool cover}) async {
    final file = await MediaService.instance.pick(
      context,
      maxWidth: cover ? 1600 : 800,
    );
    if (file == null || !mounted) return;
    final ok = await runWithProgress(
      context,
      title: cover ? 'Updating cover' : 'Updating photo',
      task: (prog) => cover
          ? UserRepository.instance.changeCover(file, onProgress: prog)
          : UserRepository.instance.changePhoto(file, onProgress: prog),
    );
    if (ok && mounted) {
      _snack(context, cover ? 'Cover updated' : 'Photo updated');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Account',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Row(
            children: [
              Avatar(url: p.photoUrl, name: p.displayName, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.displayName,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '@${p.username}',
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SettingsHeader('Profile'),
        SettingsCard(
          children: [
            SettingsTile(
              icon: Icons.edit_outlined,
              title: 'Edit profile',
              subtitle: 'Name, bio, website',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => EditProfileScreen(profile: p),
                ),
              ),
            ),
            SettingsTile(
              icon: Icons.account_circle_outlined,
              title: 'Change profile photo',
              onTap: () => _changePhoto(cover: false),
            ),
            SettingsTile(
              icon: Icons.wallpaper_outlined,
              title: 'Change cover photo',
              onTap: () => _changePhoto(cover: true),
            ),
          ],
        ),
        const SettingsHeader('Personal details'),
        SettingsCard(
          children: [
            SettingsTile(
              icon: Icons.mail_outline,
              title: 'Email',
              subtitle: p.email.isEmpty ? 'Not set' : p.email,
              trailing: const Icon(Icons.copy, size: 18),
              onTap: p.email.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: p.email));
                      _snack(context, 'Email copied');
                    },
            ),
            SettingsTile(
              key: const ValueKey('account-country'),
              icon: Icons.public,
              title: 'Country',
              subtitle: _country.isEmpty
                  ? 'Not set · tap to choose'
                  : '${flagOf(_country)}  '
                        '${countryName(_country).isEmpty ? _country : countryName(_country)}',
              onTap: _changeCountry,
            ),
            FutureBuilder<String>(
              future: _dob,
              builder: (context, s) {
                final v = s.data ?? '';
                final d = DateTime.tryParse(v);
                return SettingsTile(
                  icon: Icons.cake_outlined,
                  title: 'Date of birth',
                  subtitle: !s.hasData
                      ? 'Loading…'
                      : d == null
                      ? 'Not set'
                      : '${shortDate(d)} · only you can see this',
                  trailing: const SizedBox.shrink(),
                );
              },
            ),
          ],
        ),
        const SettingsHeader('Password and security'),
        SettingsCard(
          children: [
            SettingsTile(
              icon: Icons.password,
              title: 'Change password',
              subtitle: 'We email you a reset link',
              onTap: p.email.isEmpty ? null : _resetPassword,
            ),
          ],
        ),
      ],
    );
  }
}

// ============================================================== Accessibility

class AccessibilityScreen extends StatelessWidget {
  const AccessibilityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([s.textScale, s.reduceMotion]),
      builder: (context, _) => SettingsPage(
        title: 'Accessibility',
        children: [
          const SettingsHeader('Text size'),
          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text(
                  'This is how text looks in InstantGram.',
                  style: TextStyle(fontSize: 15 * s.textScale.value / 1),
                  textScaler: TextScaler.noScaling,
                ),
              ),
              Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(left: 16),
                    child: Text('A', style: TextStyle(fontSize: 13)),
                  ),
                  Expanded(
                    child: Slider(
                      value: s.textScale.value,
                      min: 0.8,
                      max: 1.4,
                      divisions: 6,
                      label: '${(s.textScale.value * 100).round()}%',
                      activeColor: AppColors.lime,
                      onChanged: s.setTextScale,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(right: 16),
                    child: Text('A', style: TextStyle(fontSize: 22)),
                  ),
                ],
              ),
              SettingsTile(
                icon: Icons.restart_alt,
                title: 'Reset to normal',
                onTap: () => s.setTextScale(1),
              ),
            ],
          ),
          const SettingsHeader('Motion'),
          SettingsCard(
            children: [
              SettingsSwitch(
                icon: Icons.animation,
                title: 'Reduce motion',
                subtitle: 'Fewer animations in the app',
                value: s.reduceMotion.value,
                onChanged: s.setReduceMotion,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================== Language

class LanguageScreen extends StatefulWidget {
  const LanguageScreen({super.key, required this.profile});
  final UserProfile profile;

  @override
  State<LanguageScreen> createState() => _LanguageScreenState();
}

class _LanguageScreenState extends State<LanguageScreen> {
  late String _code = widget.profile.language.isNotEmpty
      ? widget.profile.language
      : AppSettings.instance.language.value;
  String _q = '';

  Future<void> _set(String code) async {
    setState(() => _code = code);
    await AppSettings.instance.setLanguage(code);
    try {
      await UserRepository.instance.setLanguage(code);
    } catch (e) {
      if (mounted) _snack(context, friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = kLanguages
        .where(
          (l) =>
              q.isEmpty ||
              l.name.toLowerCase().contains(q) ||
              l.native.toLowerCase().contains(q),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Language')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(
                hintText: 'Search ${kLanguages.length} languages',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: Text(
              'Saved on your account. The app is in English for now — more '
              'languages are coming in future updates.',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: list.length,
              itemBuilder: (context, i) {
                final l = list[i];
                final sel = l.code == _code;
                return ListTile(
                  dense: true,
                  title: Text(
                    l.name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: l.native == l.name
                      ? null
                      : Text(
                          l.native,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                          ),
                        ),
                  trailing: sel
                      ? const Icon(Icons.check_circle, color: AppColors.lime)
                      : null,
                  onTap: () => _set(l.code),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================== Update

class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.pageUrl,
    required this.downloadUrl,
    required this.notes,
    this.published,
  });

  final String version;
  final String pageUrl;
  final String downloadUrl;
  final String notes;
  final DateTime? published;

  static ReleaseInfo? fromJson(Map<String, dynamic> j) {
    final tag = j['tag_name'];
    if (tag is! String || tag.isEmpty) return null;
    var apk = '';
    final assets = j['assets'];
    if (assets is List) {
      for (final a in assets) {
        if (a is Map && '${a['name']}'.toLowerCase().endsWith('.apk')) {
          apk = '${a['browser_download_url']}';
          break;
        }
      }
    }
    final page = j['html_url'] is String
        ? j['html_url'] as String
        : AppInfo.releasesPage;
    return ReleaseInfo(
      version: tag.replaceFirst(RegExp(r'^[vV]'), ''),
      pageUrl: page,
      downloadUrl: apk.isEmpty ? page : apk,
      notes: j['body'] is String ? j['body'] as String : '',
      published: DateTime.tryParse('${j['published_at']}'),
    );
  }
}

class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  bool _loading = false;
  String? _message;
  ReleaseInfo? _latest;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() {
      _loading = true;
      _message = null;
      _latest = null;
    });
    try {
      final res = await http
          .get(
            Uri.parse(AppInfo.latestReleaseApi),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'InstantGram-App',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 404) {
        _message = 'No app releases are published yet.';
      } else if (res.statusCode != 200) {
        _message = 'Could not check for updates (${res.statusCode}).';
      } else {
        final r = ReleaseInfo.fromJson(
          jsonDecode(res.body) as Map<String, dynamic>,
        );
        if (r == null) {
          _message = 'Could not read the latest release.';
        } else {
          _latest = r;
        }
      }
    } catch (_) {
      _message = 'No internet connection. Try again.';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final r = _latest;
    final newer = r != null && compareVersions(r.version, AppInfo.version) > 0;
    return SettingsPage(
      title: 'App update',
      children: [
        const SizedBox(height: 24),
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              gradient: AppColors.fabGradient,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Icon(
              newer ? Icons.system_update : Icons.verified_outlined,
              size: 36,
              color: Colors.black,
            ),
          ),
        ),
        const SizedBox(height: 14),
        const Center(
          child: Text(
            'Installed version ${AppInfo.version}',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Text(
                      r == null
                          ? (_message ?? '')
                          : newer
                          ? 'New version ${r.version} is available'
                          : "You're up to date",
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (r != null && r.published != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Released ${shortDate(r.published!.toLocal())}',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    ],
                    const SizedBox(height: 18),
                    if (newer)
                      IgPrimaryButton(
                        label: 'Download update',
                        icon: Icons.download,
                        height: 46,
                        onPressed: () => openLink(context, r.downloadUrl),
                      )
                    else
                      IgOutlineButton(
                        label: 'Check again',
                        icon: Icons.refresh,
                        height: 42,
                        onPressed: _check,
                      ),
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: () => openLink(context, AppInfo.releasesPage),
                      child: const Text('All releases'),
                    ),
                    if (newer && r.notes.trim().isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Text(
                          r.notes.trim(),
                          style: const TextStyle(fontSize: 13, height: 1.4),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    const Text(
                      'After downloading, open the APK file to install it. '
                      'Android may ask you to allow installs from your browser.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

// ============================================================== About

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'About',
      children: [
        const SizedBox(height: 28),
        const Center(child: IgLogo(size: 40)),
        const SizedBox(height: 8),
        const Center(
          child: Text(
            'Version ${AppInfo.version}',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(height: 6),
        const Center(
          child: Text(
            'Made by ${AppInfo.company}',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 22),
        SettingsCard(
          children: [
            SettingsTile(
              icon: Icons.mail_outline,
              title: 'Contact us',
              subtitle: AppInfo.supportEmail,
              onTap: () => openEmail(
                context,
                to: AppInfo.supportEmail,
                subject: 'InstantGram help (v${AppInfo.version})',
              ),
            ),
            SettingsTile(
              icon: Icons.code,
              title: 'Releases',
              subtitle: 'github.com/${AppInfo.githubRepo}',
              onTap: () => openLink(context, AppInfo.releasesPage),
            ),
            ValueListenableBuilder<List<String>>(
              valueListenable: AppSettings.instance.errorLog,
              builder: (context, log, _) => SettingsTile(
                key: const ValueKey('about-errors'),
                icon: Icons.bug_report_outlined,
                title: 'Error log',
                subtitle: log.isEmpty
                    ? 'No errors'
                    : '${log.length} saved · send it to us if something breaks',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ErrorLogScreen(),
                  ),
                ),
              ),
            ),
            SettingsTile(
              icon: Icons.article_outlined,
              title: 'Open-source licenses',
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'InstantGram',
                applicationVersion: AppInfo.version,
                applicationLegalese: '© ${AppInfo.company}',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ============================================================== Error log

/// Errors saved on this phone (newest first). Copy or email them.
class ErrorLogScreen extends StatelessWidget {
  const ErrorLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return ValueListenableBuilder<List<String>>(
      valueListenable: settings.errorLog,
      builder: (context, log, _) {
        final text = log.join('\n\n');
        return Scaffold(
          appBar: AppBar(
            title: const Text('Error log'),
            actions: [
              if (log.isNotEmpty)
                IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: settings.clearErrors,
                ),
            ],
          ),
          body: log.isEmpty
              ? const Center(
                  child: Text(
                    'No errors saved 🎉',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.all(14),
                        itemCount: log.length,
                        separatorBuilder: (context, i) =>
                            const Divider(color: AppColors.border),
                        itemBuilder: (context, i) => SelectableText(
                          log[i],
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: IgOutlineButton(
                                label: 'Copy',
                                icon: Icons.copy,
                                height: 44,
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(text: text));
                                  _snack(context, 'Error log copied');
                                },
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: IgPrimaryButton(
                                label: 'Email us',
                                icon: Icons.mail_outline,
                                height: 44,
                                onPressed: () => openEmail(
                                  context,
                                  to: AppInfo.supportEmail,
                                  subject:
                                      'InstantGram error log (v${AppInfo.version})',
                                  body: text.length > 6000
                                      ? text.substring(0, 6000)
                                      : text,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

// ============================================================== Legal

class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key, required this.privacy});
  final bool privacy;

  @override
  Widget build(BuildContext context) {
    final sections = privacy ? kPrivacyPolicy : kTerms;
    return SettingsPage(
      title: privacy ? 'Privacy policy' : 'Terms of use',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Text(
            'Last updated: 13 Oct 2026 · ${AppInfo.company}',
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        for (final s in sections) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Text(
              s.$1,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              s.$2,
              style: const TextStyle(fontSize: 14, height: 1.45),
            ),
          ),
        ],
      ],
    );
  }
}

const List<(String, String)> kPrivacyPolicy = [
  (
    'What we collect',
    'Your name, username, email, date of birth (private), language, profile '
        'photo and cover, the photos, clips, moments, captions, comments and '
        'messages you post, and who you follow. On your phone only, the app '
        'keeps your watch history and daily time used.',
  ),
  (
    'How we use it',
    'To run InstantGram: show your profile and posts, deliver messages, '
        'send notifications, keep accounts safe and check that users are at '
        'least 13 years old. We do not sell your data.',
  ),
  (
    'Where it is stored',
    'Accounts and posts data are stored with Google Firebase. Photos and '
        'videos are stored with Tigris storage. Uploads go through our '
        'server on Vercel. These providers keep data secure on our behalf.',
  ),
  (
    'Who can see your content',
    'Public accounts: anyone on InstantGram. Private accounts: only approved '
        'followers. Each post can also be set to Everyone, Followers or Only '
        'me. Moments disappear after 24 hours. Your date of birth is never '
        'shown to others.',
  ),
  (
    'Your choices',
    'You can edit your profile, delete posts and moments, make your account '
        'private, block people and clear your history on this phone. To '
        'delete your account, use Settings → Delete account to email us; we '
        'remove your data within 30 days.',
  ),
  ('Contact', 'Questions about privacy: ${AppInfo.supportEmail}'),
];

const List<(String, String)> kTerms = [
  (
    'Using InstantGram',
    'You must be at least 13 years old. Keep your login details safe — you '
        'are responsible for activity on your account.',
  ),
  (
    'Your content',
    'You own what you post. By posting, you allow InstantGram to store and '
        'show it to the audience you choose. Only post content you have the '
        'right to share.',
  ),
  (
    'Not allowed',
    'Nudity or sexual content, hate speech, violence, bullying or harassment, '
        'scams, spam, false information, and anything illegal. Do not copy '
        'other people\'s content or pretend to be someone else.',
  ),
  (
    'Reports and removal',
    'You can report posts and accounts by email to ${AppInfo.supportEmail}. '
        'We may remove content or disable accounts that break these terms.',
  ),
  (
    'The service',
    'InstantGram is provided "as is". Features may change, and the service '
        'may sometimes be unavailable. We are not responsible for content '
        'posted by users.',
  ),
  ('Contact', 'Questions about these terms: ${AppInfo.supportEmail}'),
];
