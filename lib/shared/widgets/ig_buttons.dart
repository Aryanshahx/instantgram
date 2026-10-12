import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';

/// Lime filled button ("Log in", "Edit profile").
class IgPrimaryButton extends StatelessWidget {
  const IgPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.height = 58,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final double height;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: FilledButton(
        onPressed: loading ? null : onPressed,
        style: FilledButton.styleFrom(
          padding: EdgeInsets.symmetric(horizontal: height < 42 ? 10 : 24),
          backgroundColor: AppColors.lime,
          foregroundColor: Colors.black,
          disabledBackgroundColor: AppColors.lime.withValues(alpha: 0.6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(height / 2.4),
          ),
          textStyle: TextStyle(
            fontFamily: AppTheme.fontFamily,
            fontSize: height < 42 ? 14 : (height < 52 ? 15 : 17),
            fontWeight: FontWeight.w700,
          ),
        ),
        child: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Colors.black,
                ),
              )
            : _ButtonContent(label: label, icon: icon, small: height < 42),
      ),
    );
  }
}

/// Dark outlined button ("Create an account", "Share profile").
class IgOutlineButton extends StatelessWidget {
  const IgOutlineButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.height = 58,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final double height;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.symmetric(horizontal: height < 42 ? 10 : 24),
          foregroundColor: AppColors.textPrimary,
          side: const BorderSide(color: AppColors.border, width: 1.2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(height / 2.4),
          ),
          textStyle: TextStyle(
            fontFamily: AppTheme.fontFamily,
            fontSize: height < 42 ? 14 : (height < 52 ? 15 : 17),
            fontWeight: FontWeight.w700,
          ),
        ),
        child: _ButtonContent(label: label, icon: icon, small: height < 42),
      ),
    );
  }
}

class _ButtonContent extends StatelessWidget {
  const _ButtonContent({required this.label, this.icon, this.small = false});

  final String label;
  final IconData? icon;
  final bool small;

  @override
  Widget build(BuildContext context) {
    if (icon == null) return Text(label);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: small ? 17 : 22),
        SizedBox(width: small ? 6 : 10),
        Text(label),
      ],
    );
  }
}
