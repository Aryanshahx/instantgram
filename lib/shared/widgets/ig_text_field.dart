import 'package:flutter/material.dart';

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

  @override
  State<IgTextField> createState() => _IgTextFieldState();
}

class _IgTextFieldState extends State<IgTextField> {
  bool _obscure = true;

  OutlineInputBorder _border(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(widget.height / 2.2),
    borderSide: BorderSide(color: color, width: 1.2),
  );

  @override
  Widget build(BuildContext context) {
    final verticalPad = widget.maxLines > 1 ? 18.0 : (widget.height - 24) / 2;
    return TextFormField(
      controller: widget.controller,
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
      style: const TextStyle(fontSize: 17, color: AppColors.textPrimary),
      decoration: InputDecoration(
        hintText: widget.hint,
        hintStyle: const TextStyle(fontSize: 17, color: AppColors.textHint),
        filled: true,
        fillColor: AppColors.surface.withValues(alpha: 0.85),
        contentPadding: EdgeInsets.symmetric(
          horizontal: 22,
          vertical: verticalPad,
        ),
        prefixIcon: widget.icon == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(left: 18, right: 12),
                child: Icon(widget.icon, color: const Color(0xFFC9CBB8)),
              ),
        prefixIconConstraints: const BoxConstraints(minWidth: 56),
        suffixIcon: widget.isPassword
            ? IconButton(
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(
                  _obscure
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: const Color(0xFFC9CBB8),
                ),
              )
            : null,
        enabledBorder: _border(AppColors.border),
        focusedBorder: _border(AppColors.lime.withValues(alpha: 0.7)),
        errorBorder: _border(AppColors.like.withValues(alpha: 0.7)),
        focusedErrorBorder: _border(AppColors.like),
        errorStyle: const TextStyle(color: AppColors.like),
      ),
    );
  }
}
