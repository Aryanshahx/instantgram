import 'package:flutter/material.dart';

import '../../../core/constants/countries.dart';
import '../../../core/constants/languages.dart';
import '../../../core/services/app_settings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/time_ago.dart';
import '../../profile/data/user_repository.dart';
import '../../../shared/widgets/country_picker.dart';
import '../../../shared/widgets/language_picker.dart';
import '../../../shared/widgets/glow_background.dart';
import '../../../shared/widgets/ig_buttons.dart';
import '../../../shared/widgets/ig_logo.dart';
import '../../../shared/widgets/ig_text_field.dart';
import '../data/auth_service.dart';
import '../../../shared/widgets/hi_text_check.dart';

/// Create account, step 2 (after [ChooseLanguageScreen]).
class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key, this.language = ''});

  /// Language chosen on the first screen.
  final String language;

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _dobCtrl = TextEditingController();
  final _langCtrl = TextEditingController();
  final _countryCtrl = TextEditingController();
  DateTime? _dob;
  late String _lang = widget.language;
  String _country = '';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (_lang.isNotEmpty) {
      _langCtrl.text = languageByCode(_lang)?.label ?? _lang;
    }
  }

  Future<void> _pickCountry() async {
    FocusScope.of(context).unfocus();
    final code = await showCountryPicker(context, current: _country);
    if (code == null) return;
    setState(() {
      _country = code;
      _countryCtrl.text = '${flagOf(code)}  ${countryName(code)}';
    });
  }

  Future<void> _pickDob() async {
    FocusScope.of(context).unfocus();
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 18, now.month, now.day),
      firstDate: DateTime(1900),
      lastDate: now,
      helpText: 'Date of birth',
      initialEntryMode: DatePickerEntryMode.calendarOnly,
    );
    if (d == null) return;
    setState(() {
      _dob = d;
      _dobCtrl.text = shortDate(d);
    });
  }

  Future<void> _pickLanguage() async {
    FocusScope.of(context).unfocus();
    final code = await showLanguagePicker(context, current: _lang);
    if (code == null) return;
    setState(() {
      _lang = code;
      _langCtrl.text = languageByCode(code)?.label ?? code;
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _userCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _dobCtrl.dispose();
    _langCtrl.dispose();
    _countryCtrl.dispose();
    super.dispose();
  }

  Future<void> _signup() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    // v0.18 Hyper Intelligence: no strong abuse in name / username
    if (!await hiTextOk(context, [_nameCtrl.text, _userCtrl.text])) return;
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      await AuthService.instance.signUp(
        name: _nameCtrl.text,
        username: _userCtrl.text,
        email: _emailCtrl.text,
        password: _passCtrl.text,
        birthDate: _dob!,
        language: _lang,
        country: _country,
      );
      AppSettings.instance.setLanguage(_lang);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on AuthFailure catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GlowBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Form(
              key: _formKey,
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 8),
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back),
                      style: IconButton.styleFrom(
                        backgroundColor: AppColors.surface.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const IgLogo(size: 26),
                    const SizedBox(height: 10),
                    const Text(
                      'Create your\naccount.',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.8,
                        height: 1.08,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Step 2 of 2 · join InstantGram and share your moments.',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 18),
                    IgTextField(
                      height: 48,
                      hint: 'Full name',
                      icon: Icons.person_outline,
                      controller: _nameCtrl,
                      textInputAction: TextInputAction.next,
                      textCapitalization: TextCapitalization.words,
                      autofillHints: const [AutofillHints.name],
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Enter your name'
                          : null,
                    ),
                    const SizedBox(height: 10),
                    IgTextField(
                      height: 48,
                      hint: 'Username',
                      icon: Icons.alternate_email,
                      controller: _userCtrl,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.newUsername],
                      validator: (v) {
                        final u = (v ?? '').trim().toLowerCase();
                        if (u.isEmpty) return 'Choose a username';
                        if (!AuthService.usernamePattern.hasMatch(u)) {
                          return '3-30 chars: letters, numbers, . and _';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 10),
                    IgTextField(
                      height: 48,
                      hint: 'Email',
                      icon: Icons.mail_outline,
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      validator: (v) => (v == null || !v.contains('@'))
                          ? 'Enter a valid email'
                          : null,
                    ),
                    const SizedBox(height: 10),
                    IgTextField(
                      height: 48,
                      hint: 'Password',
                      icon: Icons.lock_outline,
                      controller: _passCtrl,
                      isPassword: true,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.newPassword],
                      validator: (v) => (v == null || v.length < 6)
                          ? 'At least 6 characters'
                          : null,
                    ),
                    const SizedBox(height: 10),
                    IgTextField(
                      height: 48,
                      key: const ValueKey('dob'),
                      hint: 'Date of birth',
                      icon: Icons.cake_outlined,
                      controller: _dobCtrl,
                      readOnly: true,
                      onTap: _pickDob,
                      trailing: Icons.calendar_month_outlined,
                      validator: (_) {
                        final d = _dob;
                        if (d == null) return 'Enter your date of birth';
                        if (ageOn(d, DateTime.now()) < kMinAge) {
                          return 'You must be at least $kMinAge years old';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 10),
                    IgTextField(
                      height: 48,
                      key: const ValueKey('language'),
                      hint: 'Language',
                      icon: Icons.translate,
                      controller: _langCtrl,
                      readOnly: true,
                      onTap: _pickLanguage,
                      trailing: Icons.expand_more,
                      validator: (_) =>
                          _lang.isEmpty ? 'Choose your language' : null,
                    ),
                    const SizedBox(height: 10),
                    IgTextField(
                      height: 48,
                      key: const ValueKey('country'),
                      hint: 'Country',
                      icon: Icons.public,
                      controller: _countryCtrl,
                      readOnly: true,
                      onTap: _pickCountry,
                      trailing: Icons.expand_more,
                      validator: (_) =>
                          _country.isEmpty ? 'Choose your country' : null,
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(8, 8, 8, 0),
                      child: Text(
                        'Your date of birth is private. It is used to check '
                        'that you are $kMinAge or older. Your country and age '
                        'range only appear as totals in post Analytics.',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    IgPrimaryButton(
                      height: 46,
                      label: 'Sign up',
                      loading: _loading,
                      onPressed: _signup,
                    ),
                    const SizedBox(height: 10),
                    IgOutlineButton(
                      height: 46,
                      label: 'I already have an account',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
