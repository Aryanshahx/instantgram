import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/a11y.dart';
import '../../core/app_info.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../core/legal.dart';
import '../../core/ui.dart';
import '../../services/user_service.dart';
import 'settings_widgets.dart';

/// Settings > Accessibility (text size, bold text, less motion, light or dark).
class AccessibilityScreen extends StatelessWidget {
  const AccessibilityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final a = A11y.instance;
    return ListenableBuilder(
      listenable: a,
      builder: (context, _) => SettingsPage(
        title: context.tr('Accessibility'),
        children: [
          SettingsHeading(context.tr('Text size')),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 12, 0),
            child: Row(
              children: [
                const Text('A', style: TextStyle(fontSize: 14)),
                Expanded(
                  child: Slider(
                    key: const ValueKey('textScale'),
                    min: 0.8,
                    max: 1.6,
                    divisions: 8,
                    value: a.textScale,
                    label: '${(a.textScale * 100).round()}%',
                    activeColor: AppTheme.volt,
                    onChanged: (v) => a.textScale = v,
                  ),
                ),
                const Text('A', style: TextStyle(fontSize: 26)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'The quick brown fox jumps over the lazy dog.',
              style: TextStyle(color: context.muted),
            ),
          ),
          SwitchListTile(
            key: const ValueKey('boldSwitch'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            title: Text(
              context.tr('Bold text'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            value: a.boldText,
            onChanged: (v) => a.boldText = v,
          ),
          SwitchListTile(
            key: const ValueKey('motionSwitch'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            title: Text(
              context.tr('Reduce motion'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: const Text('Fewer animations and transitions'),
            value: a.reduceMotion,
            onChanged: (v) => a.reduceMotion = v,
          ),
          const SettingsHeading('Theme'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SegmentedButton<ThemeMode>(
              key: const ValueKey('themeButtons'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('Phone')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {a.themeMode},
              onSelectionChanged: (s) => a.themeMode = s.first,
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings > Language.
class LanguageScreen extends StatefulWidget {
  const LanguageScreen({super.key});

  @override
  State<LanguageScreen> createState() => _LanguageScreenState();
}

class _LanguageScreenState extends State<LanguageScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = [
      for (final l in kLanguages)
        if (q.isEmpty ||
            l.name.toLowerCase().contains(q) ||
            l.english.toLowerCase().contains(q))
          l,
    ];
    return ValueListenableBuilder<String>(
      valueListenable: Language.instance,
      builder: (context, code, _) => SettingsPage(
        title: context.tr('Language'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              key: const ValueKey('languageSearch'),
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(
                hintText: context.tr('Search'),
                prefixIcon: const Icon(Icons.search_rounded),
              ),
            ),
          ),
          for (final l in list)
            ListTile(
              key: ValueKey('language_${l.code}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              title: Text(
                l.name,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(l.english),
              trailing: code == l.code
                  ? const Icon(Icons.check_circle_rounded, color: AppTheme.mint)
                  : const Icon(Icons.circle_outlined),
              onTap: () {
                Language.instance.choose(l.code);
                UserService.instance.setLanguage(l.code).ignore();
              },
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Text(
              'Menus, Settings and the main buttons are translated. Other texts stay in English for now, and more are added with every update.',
              style: TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings > About.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: context.tr('About'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 8),
          child: Column(
            children: [
              const Text(
                kAppName,
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Version $kAppVersion',
                key: const ValueKey('aboutVersion'),
                style: TextStyle(color: context.muted),
              ),
              const SizedBox(height: 14),
              const Text(
                'Share photos, clips and moments, chat and call your people.',
                textAlign: TextAlign.center,
                style: TextStyle(height: 1.4),
              ),
            ],
          ),
        ),
        const SettingsTile(
          icon: Icons.business_rounded,
          title: 'Made by',
          subtitle: kCompany,
        ),
        SettingsTile(
          icon: Icons.mail_outline_rounded,
          title: 'Contact and help',
          subtitle: kSupportEmail,
          onTap: () async {
            final ok = await launchUrl(
              Uri(
                scheme: 'mailto',
                path: kSupportEmail,
                query: 'subject=${Uri.encodeComponent('$kAppName help')}',
              ),
            ).catchError((_) => false);
            if (!ok && context.mounted) {
              showToast(context, 'No email app found. Write to $kSupportEmail');
            }
          },
        ),
        SettingsTile(
          icon: Icons.privacy_tip_outlined,
          title: context.tr('Privacy policy'),
          onTap: () => openLegal(
            context,
            kPrivacyUrl,
            () => openScreen(context, const PrivacyPolicyScreen()),
          ),
        ),
        SettingsTile(
          icon: Icons.gavel_rounded,
          title: context.tr('Terms of use'),
          onTap: () => openLegal(
            context,
            kTermsUrl,
            () => openScreen(context, const TermsScreen()),
          ),
        ),
      ],
    );
  }
}

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) => TextPage(
    title: context.tr('Privacy policy'),
    sections: const [
      (
        'What we keep',
        'Your account details (name, username, email, date of birth, country, language), the photos, clips, moments, comments and messages you post, and simple counts such as likes and views.',
      ),
      (
        'Why we keep it',
        'To run the app: to show your content to the people you choose, to let people find and message you, and to keep the service safe. We do not sell your personal data.',
      ),
      (
        'Who can see it',
        'Posts are visible to everyone unless you pick Followers only, Only me, or switch on a private account. Messages are visible to the people in the chat. You can block anyone in Settings.',
      ),
      (
        'Where it is stored',
        'Account data and messages live in Google Firebase. Photos, clips, voice files and sounds you add from your phone live in our own media storage. Songs in Hit songs are 30 second previews from Apple (iTunes). Free music comes from the Jamendo catalogue through Openverse.',
      ),
      (
        'On your phone',
        'The app saves your language, accessibility choices, watch history and screen time on your phone only.',
      ),
      (
        'Your choices',
        'You can edit or delete your posts at any time, clear your history, and ask us to remove your account by writing to $kSupportEmail.',
      ),
      (
        'Children',
        'You must be at least 13 years old to make an account. That is why we ask for your date of birth.',
      ),
      ('Contact', 'Questions: $kSupportEmail'),
    ],
  );
}

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) => TextPage(
    title: context.tr('Terms of use'),
    sections: const [
      (
        'Using the app',
        'You must be at least 13 years old. You are responsible for your account and for what you post. Keep your password to yourself.',
      ),
      (
        'Your content',
        'You keep the rights to what you post. By posting you allow $kAppName to store and show it to the audience you choose. Only post what you have the right to share.',
      ),
      (
        'Not allowed',
        'Hate, harassment, threats, nudity or sexual content involving minors, scams, spam, violence, and content that breaks the law or other people\'s rights.',
      ),
      (
        'Audio',
        'A sound from your phone is yours: add only audio you have the right to use. It is uploaded when you share your post and removed with it. Hit songs are 30 second previews that Apple offers to promote its music; they belong to their owners and are used only inside the app, with the artist\'s name shown. Free music is shared by its artists under Creative Commons licences (the Jamendo catalogue, found through Openverse). Do not copy or resell any of it.',
      ),
      (
        'Reports and removal',
        'People can report clips from the Clips screen. We may remove content or accounts that break these terms.',
      ),
      (
        'Changes',
        'We may update these terms. Using the app after a change means you accept it.',
      ),
      ('Contact', 'Questions or reports: $kSupportEmail'),
    ],
  );
}

/// Settings > App update: asks GitHub for the newest published version.
class AppUpdateScreen extends StatefulWidget {
  const AppUpdateScreen({super.key});

  /// Tests replace this (returns the release JSON, or null when there is none).
  static Future<Map<String, dynamic>?> Function()? fetcher;

  @override
  State<AppUpdateScreen> createState() => _AppUpdateScreenState();
}

class _AppUpdateScreenState extends State<AppUpdateScreen> {
  bool _checking = false;
  String? _latest;
  String _notes = '';
  String _url = kReleasesPage;
  String? _message;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<Map<String, dynamic>?> _fetch() async {
    final f = AppUpdateScreen.fetcher;
    if (f != null) return f();
    try {
      final res = await Dio().get<Map<String, dynamic>>(
        kReleasesApi,
        options: Options(
          headers: {'Accept': 'application/vnd.github+json'},
          receiveTimeout: const Duration(seconds: 12),
          sendTimeout: const Duration(seconds: 12),
        ),
      );
      return res.data;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _message = null;
    });
    try {
      final r = await _fetch();
      if (!mounted) return;
      if (r == null) {
        setState(() {
          _latest = null;
          _message = 'No newer version has been published.';
        });
      } else {
        final tag = (r['tag_name'] as String?) ?? '';
        String url = (r['html_url'] as String?) ?? kReleasesPage;
        final assets = r['assets'];
        if (assets is List) {
          for (final a in assets) {
            if (a is Map &&
                (a['name'] as String? ?? '').endsWith('.apk') &&
                a['browser_download_url'] is String) {
              url = a['browser_download_url'] as String;
              break;
            }
          }
        }
        setState(() {
          _latest = tag;
          _notes = (r['body'] as String?) ?? '';
          _url = url;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Could not check. Check your connection.');
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final latest = _latest;
    final newer = latest != null && isNewerVersion(latest, kAppVersion);
    return SettingsPage(
      title: context.tr('App update'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Installed: $kAppVersion',
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 10),
              if (_checking)
                const LinearProgressIndicator()
              else if (newer) ...[
                Text(
                  'New version: ${latest.replaceFirst(RegExp('^v'), '')}',
                  key: const ValueKey('updateAvailable'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: AppTheme.mint,
                  ),
                ),
                if (_notes.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_notes.trim(), style: const TextStyle(height: 1.4)),
                ],
                const SizedBox(height: 14),
                FilledButton.icon(
                  key: const ValueKey('downloadUpdate'),
                  onPressed: () async {
                    final ok = await launchUrl(
                      Uri.parse(_url),
                      mode: LaunchMode.externalApplication,
                    ).catchError((_) => false);
                    if (!ok && context.mounted) {
                      showToast(context, 'Could not open the download.');
                    }
                  },
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Download'),
                ),
              ] else
                Text(
                  _message ?? 'You have the newest version.',
                  key: const ValueKey('upToDate'),
                  style: TextStyle(color: context.muted),
                ),
              const SizedBox(height: 14),
              OutlinedButton(
                key: const ValueKey('checkUpdate'),
                onPressed: _checking ? null : _check,
                child: Text(context.tr('Check for updates')),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
