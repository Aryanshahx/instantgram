import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/glow_background.dart';
import '../../../shared/widgets/ig_buttons.dart';
import '../../../shared/widgets/ig_logo.dart';
import '../data/auth_service.dart';

/// v0.0.1 sign up: type the 6 digit code we emailed to [email].
/// When it is right, [onVerified] makes the account (its errors are shown
/// here, so the person can try again).
class EmailCodeScreen extends StatefulWidget {
  const EmailCodeScreen({
    super.key,
    required this.email,
    required this.onVerified,
    this.resendIn = 60,
  });

  final String email;
  final int resendIn;
  final Future<void> Function(String otpToken) onVerified;

  @override
  State<EmailCodeScreen> createState() => _EmailCodeScreenState();
}

class _EmailCodeScreenState extends State<EmailCodeScreen> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  Timer? _tick;
  late int _wait = widget.resendIn;
  bool _busy = false;
  bool _sending = false;
  String? _error;

  /// A right code is used once: kept for a retry of the account step.
  String? _token;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_wait <= 1) {
        t.cancel();
        setState(() => _wait = 0);
      } else {
        setState(() => _wait--);
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final code = _ctrl.text.trim();
    if (_busy) return;
    if (_token == null && code.length != 6) {
      setState(() => _error = 'Enter the 6 digit code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _token ??= await AuthService.instance.verifySignupCode(
        widget.email,
        code,
      );
      await widget.onVerified(_token!);
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    if (_wait > 0 || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final s = await AuthService.instance.sendSignupCode(widget.email);
      if (!mounted) return;
      _ctrl.clear();
      _token = null;
      setState(() => _wait = s);
      _startTimer();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('New code sent')));
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('otp-screen'),
      body: GlowBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                IconButton(
                  onPressed: _busy
                      ? null
                      : () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back),
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.surface.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 10),
                const IgLogo(size: 26),
                const SizedBox(height: 10),
                const Text(
                  'Check your\nemail.',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.8,
                    height: 1.08,
                  ),
                ),
                const SizedBox(height: 8),
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: 'We sent a 6 digit code to '),
                      TextSpan(
                        text: widget.email,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const TextSpan(text: '. Also look in Spam.'),
                    ],
                  ),
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  height: 58,
                  decoration: BoxDecoration(
                    color: AppColors.surface.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _error != null ? AppColors.like : AppColors.border,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: TextField(
                    key: const ValueKey('otp-field'),
                    controller: _ctrl,
                    focusNode: _focus,
                    autofocus: true,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 12,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: '••••••',
                      hintStyle: TextStyle(
                        color: AppColors.textHint,
                        letterSpacing: 12,
                      ),
                      counterText: '',
                    ),
                    onChanged: (v) {
                      if (_error != null) setState(() => _error = null);
                      _token = null;
                      if (v.length == 6) _verify();
                    },
                    onSubmitted: (_) => _verify(),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                    child: Text(
                      _error!,
                      key: const ValueKey('otp-error'),
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.like,
                      ),
                    ),
                  ),
                const SizedBox(height: 18),
                IgPrimaryButton(
                  key: const ValueKey('otp-verify'),
                  height: 46,
                  label: 'Verify and sign up',
                  loading: _busy,
                  onPressed: _verify,
                ),
                const SizedBox(height: 6),
                Center(
                  child: TextButton(
                    key: const ValueKey('otp-resend'),
                    onPressed: _wait > 0 || _sending || _busy ? null : _resend,
                    child: Text(
                      _sending
                          ? 'Sending…'
                          : _wait > 0
                          ? 'Send again in ${_wait}s'
                          : 'Send again',
                      style: TextStyle(
                        color: _wait > 0 ? AppColors.textHint : AppColors.lime,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
