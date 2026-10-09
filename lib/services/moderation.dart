import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/mod_words.dart';
import '../core/errors.dart';
import 'app_prefs.dart';

/// One bad word found in a text: where it is and how bad.
class ModHit {
  const ModHit(this.start, this.end, this.word, {required this.blocked});
  final int start;
  final int end;

  /// The list entry it matched.
  final String word;
  final bool blocked;
}

/// What [WordFilter.scan] found.
class ModScan {
  const ModScan(this.hits, this.phrases);
  final List<ModHit> hits;

  /// Blocked phrases ("kill yourself"...) found in the text.
  final List<String> phrases;

  bool get blocked => phrases.isNotEmpty || hits.any((h) => h.blocked);
  bool get clean => hits.isEmpty && phrases.isEmpty;
}

const _leet = {
  '0': 'o',
  '1': 'i',
  '3': 'e',
  '4': 'a',
  '5': 's',
  '7': 't',
  '8': 'b',
  '@': 'a',
  '\$': 's',
  '!': 'i',
  '|': 'i',
};

final RegExp _tokenRe = RegExp(r"[\p{L}\p{M}\p{N}@$*!|#']+", unicode: true);
final RegExp _notLetter = RegExp(r'[^\p{L}\p{M}*]', unicode: true);
final RegExp _letter = RegExp(r'[\p{L}\p{M}]', unicode: true);

/// "fuuuck" -> "fuck" (every run of one letter becomes one letter).
String collapseRuns(String s) {
  final b = StringBuffer();
  String? last;
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    if (c != last) b.write(c);
    last = c;
  }
  return b.toString();
}

bool _hasDouble(String s) {
  final r = s.runes.toList();
  for (var i = 1; i < r.length; i++) {
    if (r[i] == r[i - 1]) return true;
  }
  return false;
}

/// Lower case, look-alike characters turned into letters (5h1t -> shit), anything that is
/// not a letter dropped ('*' is kept: it stands for a hidden letter).
String normalizeToken(String raw) {
  final b = StringBuffer();
  // @mentions and #tags: the sign is not part of the word
  final word = raw.replaceFirst(RegExp(r'^[@#]+'), '');
  for (final r in word.toLowerCase().runes) {
    final c = String.fromCharCode(r);
    b.write(_leet[c] ?? c);
  }
  return b.toString().replaceAll(_notLetter, '');
}

/// The word lists and the matching rules (the same rules run in the signer).
class WordFilter {
  WordFilter({
    required Iterable<String> blocked,
    required Iterable<String> mild,
    Iterable<String> allow = const [],
  }) {
    final ok = {for (final a in allow) a.trim().toLowerCase()};
    void add(String e, bool isBlocked) {
      final w = e.trim().toLowerCase();
      if (w.isEmpty || ok.contains(w) || ok.contains(w.replaceAll('*', ''))) {
        return;
      }
      if (w.contains(' ')) {
        if (isBlocked) _phrases.add(w.split(RegExp(r'\s+')).join(' '));
        return;
      }
      if (w.endsWith('*')) {
        final stem = normalizeToken(w.substring(0, w.length - 1));
        if (stem.length >= 3)
          _stems[stem] = isBlocked || (_stems[stem] ?? false);
        return;
      }
      final n = normalizeToken(w);
      if (n.isEmpty) return;
      _exact[n] = isBlocked || (_exact[n] ?? false);
    }

    for (final w in mild) {
      add(w, false);
    }
    for (final w in blocked) {
      add(w, true);
    }
    _allow = ok;
  }

  final Map<String, bool> _exact = {};
  final Map<String, bool> _stems = {};
  final List<String> _phrases = [];
  Set<String> _allow = const {};

  /// The entry [token] matches ('' = none) and whether it is blocked.
  (String, bool)? matchToken(String token) {
    final v = normalizeToken(token);
    if (v.isEmpty || _allow.contains(v)) return null;
    if (v.contains('*')) return _wildcard(v);
    final exact = _exact[v];
    if (exact != null) return (v, exact);
    final double = _hasDouble(v);
    final c = double ? collapseRuns(v) : v;
    if (double) {
      for (final e in _exact.entries) {
        if (collapseRuns(e.key) == c) return (e.key, e.value);
      }
    }
    for (final e in _stems.entries) {
      if (v.contains(e.key) || (double && c.contains(collapseRuns(e.key)))) {
        return ('${e.key}*', e.value);
      }
    }
    return null;
  }

  /// "f*ck", "sh**t": the stars stand for letters (at least half must be real letters).
  (String, bool)? _wildcard(String v) {
    final letters = v.replaceAll('*', '').length;
    if (letters < 2 || letters * 2 < v.length) return null;
    if (!_letter.hasMatch(v[0])) return null;
    final re = RegExp(
      '^${v.split('').map((c) => c == '*' ? '.' : RegExp.escape(c)).join()}\$',
    );
    for (final e in _exact.entries) {
      if (re.hasMatch(e.key)) return (e.key, e.value);
    }
    for (final e in _stems.entries) {
      if (e.key.length == v.length && re.hasMatch(e.key)) {
        return ('${e.key}*', e.value);
      }
    }
    return null;
  }

  ModScan scan(String text) {
    final hits = <ModHit>[];
    final toks = _tokenRe.allMatches(text).toList();
    final words = <String>[];
    var i = 0;
    while (i < toks.length) {
      final t = toks[i];
      final n = normalizeToken(t.group(0)!);
      // "f u c k" / "f.u.c.k": single letters in a row are read as one word
      if (n.length == 1) {
        var j = i;
        final b = StringBuffer();
        while (j < toks.length) {
          final nj = normalizeToken(toks[j].group(0)!);
          if (nj.length != 1) break;
          if (j > i && toks[j].start - toks[j - 1].end > 2) break;
          b.write(nj);
          j++;
        }
        if (j - i >= 3) {
          final m = matchToken(b.toString());
          if (m != null) {
            hits.add(ModHit(t.start, toks[j - 1].end, m.$1, blocked: m.$2));
          }
          words.add(b.toString());
          i = j;
          continue;
        }
      }
      final m = matchToken(t.group(0)!);
      if (m != null) hits.add(ModHit(t.start, t.end, m.$1, blocked: m.$2));
      words.add(n);
      i++;
    }
    final joined = ' ${words.join(' ')} ';
    // also without joining single letters ("a x y b")
    final plain = ' ${toks.map((t) => normalizeToken(t.group(0)!)).join(' ')} ';
    final phrases = [
      for (final p in _phrases)
        if (joined.contains(' $p ') || plain.contains(' $p ')) p,
    ];
    return ModScan(hits, phrases);
  }

  /// [text] with the found words starred (first letter kept): "f***".
  static String mask(String text, Iterable<ModHit> hits) {
    final list = hits.toList()..sort((a, b) => b.start.compareTo(a.start));
    var out = text;
    for (final h in list) {
      final w = out.substring(h.start, h.end);
      final first = String.fromCharCode(w.runes.first);
      final stars = '*' * (w.runes.length - 1).clamp(1, 30);
      out = out.replaceRange(h.start, h.end, '$first$stars');
    }
    return out;
  }
}

/// The app's text checks: defaults plus what the admin panel set (config/moderation).
class Moderation {
  Moderation._();
  static final Moderation instance = Moderation._();

  WordFilter _filter = WordFilter(blocked: kBlockedWords, mild: kMildWords);
  WordFilter get filter => _filter;

  /// Extra lists from the panel (also used by tests).
  void apply({
    List<String> blocked = const [],
    List<String> mild = const [],
    List<String> allow = const [],
  }) {
    _filter = WordFilter(
      blocked: [...kBlockedWords, ...blocked],
      mild: [...kMildWords, ...mild],
      allow: allow,
    );
  }

  /// Takes the lists saved on the phone at once, then the newest from Firestore.
  Future<void> load() async {
    _fromJson(AppPrefs.instance.modWords);
    try {
      final d = await FirebaseFirestore.instance
          .collection('config')
          .doc('moderation')
          .get();
      final m = d.data();
      if (m == null) return;
      final raw = jsonEncode({
        'blocked': m['blocked'] ?? const [],
        'mild': m['mild'] ?? const [],
        'allow': m['allow'] ?? const [],
      });
      AppPrefs.instance.modWords = raw;
      _fromJson(raw);
    } catch (_) {
      // the saved or built-in lists stay
    }
  }

  void _fromJson(String raw) {
    if (raw.isEmpty) return;
    try {
      final m = jsonDecode(raw) as Map;
      List<String> l(Object? v) => v is List
          ? [
              for (final x in v)
                if (x is String) x,
            ]
          : const [];
      apply(blocked: l(m['blocked']), mild: l(m['mild']), allow: l(m['allow']));
    } catch (_) {}
  }

  /// Public text (caption, comment, bio...): throws on a blocked word, stars swear words.
  String publicText(String text, {String what = 'text'}) {
    if (text.trim().isEmpty) return text;
    final s = _filter.scan(text);
    if (s.clean) return text;
    if (s.blocked) {
      final bad = s.phrases.isNotEmpty
          ? '"${s.phrases.first}"'
          : '"${text.substring(s.hits.firstWhere((h) => h.blocked).start, s.hits.firstWhere((h) => h.blocked).end)}"';
      throw ModerationException(
        'Your $what has words that are not allowed on InstantGram ($bad). Please change it.',
      );
    }
    return WordFilter.mask(text, s.hits);
  }

  /// A username or name: no blocked or swear words at all (they cannot be starred).
  void checkName(String text, {String what = 'username'}) {
    final s = _filter.scan(text.replaceAll(RegExp(r'[._]'), ' '));
    final whole = _filter.matchToken(text);
    if (!s.clean || whole != null) {
      throw ModerationException(
        'That $what is not allowed on InstantGram. Please pick another one.',
      );
    }
  }

  /// Chats are private: only the blocked words are starred, nothing is stopped.
  String chatText(String text) {
    final s = _filter.scan(text);
    final bad = s.hits.where((h) => h.blocked);
    return bad.isEmpty ? text : WordFilter.mask(text, bad);
  }
}
