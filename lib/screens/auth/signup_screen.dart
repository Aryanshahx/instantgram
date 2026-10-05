import 'package:flutter/material.dart';

import '../../core/errors.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/auth_service.dart';
import '../../widgets/aurora_background.dart';
import '../../widgets/brand_logo.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _fullName = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  DateTime? _birth;
  bool _birthError = false;

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')} / ${d.month.toString().padLeft(2, '0')} / ${d.year}';

  Future<void> _pickBirth() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _birth ?? DateTime(now.year - 18, now.month, now.day),
      firstDate: DateTime(now.year - 110),
      lastDate: now,
      initialEntryMode: DatePickerEntryMode.calendarOnly,
      helpText: context.tr('Choose your date of birth'),
    );
    if (d != null && mounted) {
      setState(() {
        _birth = d;
        _birthError = false;
      });
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _fullName.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    final formOk = _formKey.currentState!.validate();
    final b = _birth;
    if (b == null || !AuthService.isOldEnough(b, DateTime.now())) {
      setState(() => _birthError = true);
      return;
    }
    if (!formOk) return;
    setState(() => _loading = true);
    try {
      await AuthService.instance.signUp(
        email: _email.text,
        password: _password.text,
        username: _username.text,
        fullName: _fullName.text,
        birthDate: b,
        language: Language.instance.value,
      );
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(),
      body: AuroraBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 26),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const BrandWordmark(size: 34),
                      const SizedBox(height: 22),
                      const Text(
                        'Join the\nflow.',
                        style: TextStyle(
                          fontSize: 40,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1.8,
                          height: 1.02,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Make an account in under a minute.',
                        style: TextStyle(color: context.muted, fontSize: 15),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        context.tr('Choose your language'),
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      ValueListenableBuilder<String>(
                        valueListenable: Language.instance,
                        builder: (context, code, _) => Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final l in kLanguages.take(4))
                              ChoiceChip(
                                key: ValueKey('lang_${l.code}'),
                                label: Text(l.name),
                                selected: code == l.code,
                                showCheckmark: false,
                                selectedColor: AppTheme.volt,
                                labelStyle: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: code == l.code ? AppTheme.ink : null,
                                ),
                                onSelected: (_) => Language.instance.choose(
                                  l.code,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _fullName,
                        textCapitalization: TextCapitalization.words,
                        decoration: InputDecoration(
                          hintText: context.tr('Full name'),
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _username,
                        autocorrect: false,
                        decoration: InputDecoration(
                          hintText: context.tr('Username'),
                          helperText: '3-20 chars: a-z, 0-9, dot, underscore',
                          prefixIcon: Icon(Icons.tag_rounded),
                        ),
                        validator: (v) {
                          final u = (v ?? '').trim().toLowerCase();
                          return AuthService.usernameRegex.hasMatch(u)
                              ? null
                              : 'Invalid username';
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(
                          hintText: context.tr('Email'),
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                        validator: (v) => (v == null || !v.contains('@'))
                            ? 'Enter a valid email'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        obscureText: _obscure,
                        decoration: InputDecoration(
                          hintText: context.tr('Password'),
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_off_rounded
                                  : Icons.visibility_rounded,
                            ),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (v) => (v == null || v.length < 6)
                            ? 'At least 6 characters'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      InkWell(
                        key: const ValueKey('birthField'),
                        borderRadius: BorderRadius.circular(18),
                        onTap: _pickBirth,
                        child: InputDecorator(
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.cake_outlined),
                            errorText: _birthError
                                ? (_birth == null
                                      ? context.tr('Choose your date of birth')
                                      : context.tr(
                                          'You must be at least 13 years old.',
                                        ))
                                : null,
                          ),
                          child: Text(
                            _birth == null
                                ? context.tr('Date of birth')
                                : _fmt(_birth!),
                            style: TextStyle(
                              color: _birth == null ? context.muted : null,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      FilledButton(
                        onPressed: _loading ? null : _signUp,
                        child: _loading
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: AppTheme.ink,
                                ),
                              )
                            : Text(context.tr('Create account')),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
