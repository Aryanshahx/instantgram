import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/glow_background.dart';
import '../../../shared/widgets/ig_buttons.dart';
import '../../../shared/widgets/ig_logo.dart';
import '../../../shared/widgets/ig_text_field.dart';
import '../data/auth_service.dart';
import 'choose_language_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _idCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _idCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await AuthService.instance.signIn(
        identifier: _idCtrl.text,
        password: _passCtrl.text,
      );
      // AuthGate switches to the home screen automatically.
    } on AuthFailure catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _forgotPassword() async {
    final ctrl = TextEditingController(
      text: _idCtrl.text.contains('@') ? _idCtrl.text.trim() : '',
    );
    final email = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          0,
          24,
          24 + MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Reset password',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const Text(
              "Enter your email and we'll send you a reset link.",
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 20),
            IgTextField(
              height: 48,
              hint: 'Email',
              icon: Icons.alternate_email,
              controller: ctrl,
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 16),
            IgPrimaryButton(
              height: 46,
              label: 'Send reset link',
              onPressed: () => Navigator.pop(ctx, ctrl.text),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (email == null || !email.contains('@')) return;
    try {
      await AuthService.instance.sendPasswordReset(email);
      _snack('Reset link sent to $email');
    } on AuthFailure catch (e) {
      _snack(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GlowBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Form(
                  key: _formKey,
                  child: AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 24),
                        const IgLogo(size: 30),
                        const SizedBox(height: 18),
                        const Text(
                          'Share the\nmoment,\ninstantly.',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1.2,
                            height: 1.08,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Log in to see what your people are up to.',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 26),
                        IgTextField(
                          height: 48,
                          hint: 'Email or username',
                          icon: Icons.alternate_email,
                          controller: _idCtrl,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [
                            AutofillHints.email,
                            AutofillHints.username,
                          ],
                          validator: (v) => (v == null || v.trim().isEmpty)
                              ? 'Enter your email or username'
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
                          autofillHints: const [AutofillHints.password],
                          onSubmitted: (_) => _login(),
                          validator: (v) => (v == null || v.isEmpty)
                              ? 'Enter your password'
                              : null,
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: _forgotPassword,
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.lime,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                            ),
                            child: const Text(
                              'Forgot password?',
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        IgPrimaryButton(
                          height: 46,
                          label: 'Log in',
                          loading: _loading,
                          onPressed: _login,
                        ),
                        const SizedBox(height: 10),
                        IgOutlineButton(
                          height: 46,
                          label: 'Create an account',
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const ChooseLanguageScreen(),
                            ),
                          ),
                        ),
                        const SizedBox(height: 32),
                      ],
                    ),
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
