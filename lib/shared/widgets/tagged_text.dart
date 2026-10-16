import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../features/search/presentation/hashtag_screen.dart';

/// v0.17: text where every #hashtag is lime and can be tapped (opens the
/// hashtag page). Optional @name at the start is lime too (comments).
class TaggedText extends StatefulWidget {
  const TaggedText(
    this.text, {
    super.key,
    this.prefix = const [],
    this.style,
    this.maxLines,
    this.overflow,
    this.mentionAtStart = false,
    this.onTag,
  });

  final String text;

  /// Spans before the text (e.g. the username in bold).
  final List<InlineSpan> prefix;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool mentionAtStart;

  /// Tests / custom: what a tap on a tag does (default: hashtag page).
  final void Function(String tag)? onTag;

  /// Same letters as the saved tags (`PostRepository.extractTags`).
  static final RegExp tagRe = RegExp(
    r'#([\p{L}\p{M}\p{N}_]{1,50})',
    unicode: true,
  );

  static const TextStyle tagStyle = TextStyle(
    color: AppColors.lime,
    fontWeight: FontWeight.w600,
  );

  @override
  State<TaggedText> createState() => _TaggedTextState();
}

class _TaggedTextState extends State<TaggedText> {
  final List<TapGestureRecognizer> _taps = [];

  void _clear() {
    for (final r in _taps) {
      r.dispose();
    }
    _taps.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  void _open(String tag) {
    final f = widget.onTag;
    if (f != null) {
      f(tag);
      return;
    }
    openHashtag(context, tag);
  }

  List<InlineSpan> _spans() {
    _clear();
    var text = widget.text;
    final out = <InlineSpan>[];
    if (widget.mentionAtStart) {
      final m = RegExp(r'^@[a-z0-9._]+').firstMatch(text);
      if (m != null) {
        out.add(TextSpan(text: m.group(0), style: TaggedText.tagStyle));
        text = text.substring(m.end);
      }
    }
    var last = 0;
    for (final m in TaggedText.tagRe.allMatches(text)) {
      if (m.start > last) {
        out.add(TextSpan(text: text.substring(last, m.start)));
      }
      final tag = m.group(1)!;
      final r = TapGestureRecognizer()..onTap = () => _open(tag);
      _taps.add(r);
      out.add(
        TextSpan(text: m.group(0), style: TaggedText.tagStyle, recognizer: r),
      );
      last = m.end;
    }
    if (last < text.length) out.add(TextSpan(text: text.substring(last)));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(children: [...widget.prefix, ..._spans()]),
      style: widget.style,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }
}
