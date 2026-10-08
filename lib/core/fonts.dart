import 'package:flutter/material.dart';

/// The text styles people can choose for moment texts (and later bios and messages).
/// All fonts are inside the app (assets/fonts, free licences), so everybody sees the same.
class AppFont {
  const AppFont(this.id, this.label, this.family, {this.weight});

  /// Stored with the text ('' = the classic app font).
  final String id;
  final String label;
  final String? family;
  final FontWeight? weight;
}

const List<AppFont> kAppFonts = [
  AppFont('', 'Classic', null, weight: FontWeight.w800),
  AppFont('bebas', 'Strong', 'Bebas'),
  AppFont('marker', 'Marker', 'Marker'),
  AppFont('lobster', 'Retro', 'Lobster'),
  AppFont('script', 'Script', 'Wordmark'),
  AppFont('hand', 'Hand', 'Caveat', weight: FontWeight.w600),
  AppFont('serif', 'Elegant', 'Playfair', weight: FontWeight.w700),
  AppFont('mono', 'Typewriter', 'SpaceMono'),
];

/// A known font id, or '' (unknown ids from newer app versions fall back to Classic).
String cleanFontId(Object? v) {
  if (v is! String || v.isEmpty) return '';
  for (final f in kAppFonts) {
    if (f.id == v) return v;
  }
  return '';
}

AppFont appFont(String id) {
  for (final f in kAppFonts) {
    if (f.id == id) return f;
  }
  return kAppFonts.first;
}

/// [base] in the chosen font (family and weight).
TextStyle withAppFont(String id, TextStyle base) {
  final f = appFont(id);
  return base.copyWith(
    fontFamily: f.family,
    fontWeight: f.weight ?? FontWeight.w400,
  );
}
