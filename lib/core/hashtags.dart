import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'app_events.dart';

final RegExp _tagPattern = RegExp(r'#([\p{L}\p{N}_]{1,40})', unicode: true);

/// The hashtags in a text, lowercase, without the #, each one once.
List<String> extractHashtags(String text) {
  final seen = <String>{};
  final out = <String>[];
  for (final m in _tagPattern.allMatches(text)) {
    final t = m.group(1)!.toLowerCase();
    if (seen.add(t)) out.add(t);
  }
  return out;
}

/// A caption where every #hashtag is coloured and opens the search for it.
class HashtagText extends StatefulWidget {
  const HashtagText(
    this.text, {
    super.key,
    this.style,
    this.leading = const [],
    this.maxLines,
    this.overflow,
    this.tagColor,
    this.onTag,
  });

  final String text;
  final TextStyle? style;

  /// Spans in front of the text (for example the bold username).
  final List<InlineSpan> leading;
  final int? maxLines;
  final TextOverflow? overflow;
  final Color? tagColor;

  /// Called with the tag (no #). By default the Explore search opens with it.
  final ValueChanged<String>? onTag;

  @override
  State<HashtagText> createState() => _HashtagTextState();
}

class _HashtagTextState extends State<HashtagText> {
  final List<TapGestureRecognizer> _taps = [];

  void _clear() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  void _open(String tag) {
    final cb = widget.onTag;
    if (cb != null) {
      cb(tag);
      return;
    }
    Navigator.of(context).popUntil((r) => r.isFirst);
    AppEvents.openSearch('#$tag');
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final color = widget.tagColor ?? Theme.of(context).colorScheme.primary;
    final spans = <InlineSpan>[...widget.leading];
    var at = 0;
    final text = widget.text;
    for (final m in _tagPattern.allMatches(text)) {
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
      final tag = m.group(1)!.toLowerCase();
      final tap = TapGestureRecognizer()..onTap = () => _open(tag);
      _taps.add(tap);
      spans.add(
        TextSpan(
          text: m.group(0),
          recognizer: tap,
          style: TextStyle(color: color, fontWeight: FontWeight.w700),
        ),
      );
      at = m.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(
      TextSpan(children: spans),
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      style: widget.style,
    );
  }
}
