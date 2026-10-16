import 'package:flutter/material.dart';

import '../../core/constants/languages.dart';
import '../../core/services/app_settings.dart';
import '../../core/services/translator.dart';
import '../../core/theme/app_colors.dart';

/// v0.19: text with a small "See translation" link under it (captions,
/// comments, bios). Tap -> the text is shown in your language,
/// "See original" -> back. Only shown when the text looks like another
/// language than yours (Settings -> Language).
///
/// [builder] draws the text: the original, or the translation
/// (translated = true).
class SeeTranslation extends StatefulWidget {
  const SeeTranslation({
    super.key,
    required this.text,
    required this.builder,
    this.linkPadding = const EdgeInsets.only(top: 3),
    this.light = false,
  });

  final String text;
  final Widget Function(String text, bool translated) builder;
  final EdgeInsets linkPadding;

  /// On dark video (Clips): a lighter link.
  final bool light;

  @override
  State<SeeTranslation> createState() => _SeeTranslationState();
}

enum _St { idle, loading, shown, failed }

class _SeeTranslationState extends State<SeeTranslation> {
  _St _st = _St.idle;
  Translation? _t;

  @override
  void didUpdateWidget(SeeTranslation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _st = _St.idle;
      _t = null;
    }
  }

  Future<void> _tap() async {
    switch (_st) {
      case _St.loading:
        return;
      case _St.shown:
        if (_t?.to == Translator.instance.target) {
          setState(() => _st = _St.idle);
          return;
        }
        continue translate;
      translate:
      case _St.idle:
      case _St.failed:
        final t = _t;
        if (t != null && t.to == Translator.instance.target) {
          setState(() => _st = _St.shown);
          return;
        }
        setState(() => _st = _St.loading);
        final asked = widget.text;
        try {
          final r = await Translator.instance.translate(asked);
          // v0.20: the list reused this widget for other text meanwhile
          if (!mounted || widget.text != asked) return;
          setState(() {
            _t = r;
            _st = _St.shown;
          });
        } catch (_) {
          if (mounted && widget.text == asked) {
            setState(() => _st = _St.failed);
          }
        }
    }
  }

  String _label(_St st, Translation? t) {
    switch (st) {
      case _St.idle:
        return 'See translation';
      case _St.loading:
        return 'Translating…';
      case _St.failed:
        return "Couldn't translate · Try again";
      case _St.shown:
        final from = t == null ? null : languageByCode(t.from)?.name;
        return from == null
            ? 'See original'
            : 'See original · Translated from $from';
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: AppSettings.instance.language,
      builder: (context, lang, _) {
        final to = lang.isEmpty ? 'en' : lang;
        final t = _t;
        final shown = _st == _St.shown && t != null && t.to == to;
        final offer = Translator.shouldOffer(widget.text, to);
        // already in your language: no link (after the first tap)
        if (!offer || (t != null && t.same && t.to == to)) {
          return widget.builder(widget.text, false);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            shown
                ? widget.builder(t.text, true)
                : widget.builder(widget.text, false),
            GestureDetector(
              key: const ValueKey('see-translation'),
              behavior: HitTestBehavior.opaque,
              onTap: _tap,
              child: Padding(
                padding: widget.linkPadding,
                child: Text(
                  shown
                      ? _label(_St.shown, t)
                      : _label(_st == _St.shown ? _St.idle : _st, null),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: widget.light
                        ? Colors.white70
                        : AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
