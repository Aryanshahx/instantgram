import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';

/// Rounded dark input used on Login / Search / Chats.
class IgTextField extends StatefulWidget {
  const IgTextField({
    super.key,
    required this.hint,
    this.icon,
    this.controller,
    this.isPassword = false,
    this.keyboardType,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.validator,
    this.autofillHints,
    this.height = 64,
    this.maxLines = 1,
    this.textCapitalization = TextCapitalization.none,
    this.readOnly = false,
    this.onTap,
    this.trailing,
    this.inputFormatters,
    this.maxLength,
    this.fieldKey,
  });

  final String hint;
  final IconData? icon;
  final TextEditingController? controller;
  final bool isPassword;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FormFieldValidator<String>? validator;
  final Iterable<String>? autofillHints;
  final double height;
  final int maxLines;
  final TextCapitalization textCapitalization;

  /// Tap-only field (e.g. opens a date picker).
  final bool readOnly;
  final VoidCallback? onTap;

  /// Icon on the right (ignored for password fields).
  final IconData? trailing;

  /// e.g. lower case only (usernames).
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLength;

  /// Key of the inner text field (tests).
  final Key? fieldKey;

  @override
  State<IgTextField> createState() => _IgTextFieldState();
}

class _IgTextFieldState extends State<IgTextField> {
  bool _obscure = true;

  OutlineInputBorder _border(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(
      widget.maxLines > 1 ? 16 : widget.height / 2.2,
    ),
    borderSide: BorderSide(color: color, width: 1.2),
  );

  @override
  Widget build(BuildContext context) {
    // Small fields (height < 52) get smaller text + icons.
    final compact = widget.height < 52;
    final fontSize = compact ? 15.0 : 17.0;
    final verticalPad = widget.maxLines > 1
        ? (compact ? 12.0 : 18.0)
        : (widget.height - fontSize * 1.4) / 2;
    return TextFormField(
      key: widget.fieldKey,
      controller: widget.controller,
      inputFormatters: widget.inputFormatters,
      maxLength: widget.maxLength,
      obscureText: widget.isPassword && _obscure,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      onChanged: widget.onChanged,
      onFieldSubmitted: widget.onSubmitted,
      validator: widget.validator,
      autofillHints: widget.autofillHints,
      maxLines: widget.isPassword ? 1 : widget.maxLines,
      minLines: 1,
      textCapitalization: widget.textCapitalization,
      readOnly: widget.readOnly,
      onTap: widget.onTap,
      showCursor: widget.readOnly ? false : null,
      style: TextStyle(fontSize: fontSize, color: AppColors.textPrimary),
      decoration: InputDecoration(
        hintText: widget.hint,
        counterText: '',
        hintStyle: TextStyle(fontSize: fontSize, color: AppColors.textHint),
        filled: true,
        fillColor: AppColors.surface.withValues(alpha: 0.85),
        contentPadding: EdgeInsets.symmetric(
          horizontal: compact ? 16 : 22,
          vertical: verticalPad,
        ),
        prefixIcon: widget.icon == null
            ? null
            : Padding(
                padding: EdgeInsets.only(
                  left: compact ? 14 : 18,
                  right: compact ? 8 : 12,
                ),
                child: Icon(
                  widget.icon,
                  size: compact ? 20 : 24,
                  color: const Color(0xFFC9CBB8),
                ),
              ),
        prefixIconConstraints: BoxConstraints(minWidth: compact ? 42 : 56),
        suffixIcon: widget.isPassword
            ? IconButton(
                onPressed: () => setState(() => _obscure = !_obscure),
                iconSize: compact ? 20 : 24,
                icon: Icon(
                  _obscure
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: const Color(0xFFC9CBB8),
                ),
              )
            : (widget.trailing == null
                  ? null
                  : Padding(
                      padding: EdgeInsets.only(right: compact ? 10 : 14),
                      child: Icon(
                        widget.trailing,
                        size: compact ? 20 : 24,
                        color: const Color(0xFFC9CBB8),
                      ),
                    )),
        enabledBorder: _border(AppColors.border),
        focusedBorder: _border(AppColors.lime.withValues(alpha: 0.7)),
        errorBorder: _border(AppColors.like.withValues(alpha: 0.7)),
        focusedErrorBorder: _border(AppColors.like),
        errorStyle: const TextStyle(color: AppColors.like),
      ),
    );
  }
}
