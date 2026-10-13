import 'package:flutter/material.dart';

import '../../../core/constants/languages.dart';
import '../../../core/services/app_settings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/glow_background.dart';
import '../../../shared/widgets/ig_buttons.dart';
import '../../../shared/widgets/ig_logo.dart';
import 'signup_screen.dart';

/// Create account, step 1: choose your language.
class ChooseLanguageScreen extends StatefulWidget {
  const ChooseLanguageScreen({super.key});

  @override
  State<ChooseLanguageScreen> createState() => _ChooseLanguageScreenState();
}

class _ChooseLanguageScreenState extends State<ChooseLanguageScreen> {
  String _code = '';
  String _q = '';

  void _next() {
    if (_code.isEmpty) return;
    AppSettings.instance.setLanguage(_code);
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => SignupScreen(language: _code)),
    );
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
      body: GlowBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back),
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.surface.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 14),
                const IgLogo(size: 24),
                const SizedBox(height: 12),
                const Text(
                  'Choose your\nlanguage',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.2,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Step 1 of 2 · you can change it later in Settings',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 14),
                TextField(
                  key: const ValueKey('lang-search'),
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
                const SizedBox(height: 8),
                Expanded(
                  child: Material(
                    color: AppColors.surface.withValues(alpha: 0.6),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                      side: const BorderSide(color: AppColors.border),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: list.isEmpty
                        ? const Center(
                            child: Text(
                              'No language found',
                              style: TextStyle(color: AppColors.textSecondary),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: list.length,
                            itemBuilder: (context, i) {
                              final l = list[i];
                              final sel = l.code == _code;
                              return ListTile(
                                key: ValueKey('lang-${l.code}'),
                                dense: true,
                                title: Text(
                                  l.name,
                                  style: const TextStyle(
                                    fontFamily: AppTheme.fontFamily,
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
                                trailing: Icon(
                                  sel
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_off,
                                  color: sel
                                      ? AppColors.lime
                                      : AppColors.textSecondary,
                                ),
                                onTap: () => setState(() => _code = l.code),
                              );
                            },
                          ),
                  ),
                ),
                const SizedBox(height: 14),
                IgPrimaryButton(
                  height: 46,
                  key: const ValueKey('lang-continue'),
                  label: 'Continue',
                  onPressed: _code.isEmpty ? null : _next,
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
