import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/errors.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../services/auth_service.dart';
import '../../widgets/aurora_background.dart';
import '../../widgets/brand_logo.dart';
import 'signup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await AuthService.instance.signIn(
        identifier: _email.text,
        password: _password.text,
      );
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _forgot() async {
    await showDialog<void>(
      context: context,
      builder: (_) => ForgotPasswordDialog(initial: _email.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                      const SizedBox(height: 30),
                      const Text(
                        'Share the moment,\ninstantly.',
                        style: TextStyle(
                          fontSize: 40,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1.8,
                          height: 1.02,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Log in to see what your people are up to.',
                        style: TextStyle(color: context.muted, fontSize: 15),
                      ),
                      const SizedBox(height: 28),
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                        autofillHints: const [AutofillHints.username],
                        decoration: const InputDecoration(
                          hintText: 'Email or username',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Enter your email or username'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.password],
                        decoration: InputDecoration(
                          hintText: 'Password',
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
                        validator: (v) => (v == null || v.isEmpty)
                            ? 'Enter your password'
                            : null,
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _forgot,
                          child: const Text('Forgot password?'),
                        ),
                      ),
                      FilledButton(
                        onPressed: _loading ? null : _login,
                        child: _loading
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: AppTheme.ink,
                                ),
                              )
                            : const Text('Log in'),
                      ),
                      const SizedBox(height: 14),
                      OutlinedButton(
                        onPressed: () =>
                            openScreen(context, const SignupScreen()),
                        child: const Text('Create an account'),
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

/// "Forgot password?": asks for an email or a username, sends the reset link and says where it
/// went. Shows what is wrong in the dialog itself (it is not hidden behind a toast).
class ForgotPasswordDialog extends StatefulWidget {
  const ForgotPasswordDialog({super.key, this.initial = ''});
  final String initial;

  @override
  State<ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<ForgotPasswordDialog> {
  late final TextEditingController _id = TextEditingController(
    text: widget.initial,
  );
  bool _busy = false;
  String? _error;
  String? _sentTo;

  @override
  void dispose() {
    _id.dispose();
    super.dispose();
  }

  static String _resetError(Object e) {
    if (e is FirebaseAuthException) {
      switch (e.code) {
        case 'user-not-found':
          return 'No account uses that email.';
        case 'invalid-email':
          return 'That email address is not valid.';
        case 'too-many-requests':
          return 'Too many tries. Wait a few minutes and try again.';
        case 'network-request-failed':
          return 'No internet connection.';
        case 'missing-android-pkg-name':
        case 'unauthorized-continue-uri':
        case 'operation-not-allowed':
          return 'Password reset is switched off for this project in Firebase.';
      }
      return 'Could not send the email (${e.code}).';
    }
    return friendlyError(e);
  }

  Future<void> _send() async {
    final id = _id.text.trim();
    if (id.isEmpty) {
      setState(() => _error = 'Enter your email or username.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final to = await AuthService.instance.sendPasswordReset(id);
      if (mounted) setState(() => _sentTo = to);
    } catch (e) {
      if (mounted) setState(() => _error = _resetError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sent = _sentTo;
    return AlertDialog(
      title: Text(sent == null ? 'Reset password' : 'Check your email'),
      content: SingleChildScrollView(
        child: sent == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Enter your email or username and we will send you a link to choose a new password.',
                    style: TextStyle(color: context.muted),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _id,
                    autofocus: true,
                    autocorrect: false,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _busy ? null : _send(),
                    decoration: const InputDecoration(
                      hintText: 'Email or username',
                      prefixIcon: Icon(Icons.alternate_email_rounded),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      style: const TextStyle(color: Color(0xFFFF5C6C)),
                    ),
                  ],
                ],
              )
            : Text(
                'We sent a link to $sent.\n\nIt can take a minute to arrive. If you do not see it, look in your spam folder.',
              ),
      ),
      actions: [
        if (sent == null)
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        if (sent == null)
          TextButton(
            onPressed: _busy ? null : _send,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : const Text('Send link'),
          )
        else
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
      ],
    );
  }
}
